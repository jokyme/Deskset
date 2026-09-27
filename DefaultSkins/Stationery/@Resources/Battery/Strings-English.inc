; Stationery · Battery — the widget's words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim it.

[Variables]
; ---------------------------------------------------------------- menu (Energy on a Mac without a battery)
BatteryMenuOpen=Open Battery Settings
BatteryMenuOpenEnergy=Open Energy Settings

; ---------------------------------------------------------------- the status line under the percentage
; by state (%1 is a duration such as "4 h 12 min"): 1 charging, 2 charging with an estimate, 3 on battery, 4 on
; battery while macOS estimates, 5 fully charged, 6 charging paused, 7 Low Power Mode
BatteryStatus0=
BatteryStatus1=Charging
BatteryStatus2=%1 until full
BatteryStatus3=%1 left
BatteryStatus4=On battery
BatteryStatus5=Fully charged
BatteryStatus6=Charging paused
BatteryStatus7=Low Power Mode

; ---------------------------------------------------------------- the Medium's rows
BatteryHealth=Health
BatteryCycles=Cycles
BatteryTemperature=Temperature
BatteryPower=Power
BatteryAdapter=Adapter
BatteryUnplugged=Unplugged
BatteryPowerAdapter=Power adapter

; ---------------------------------------------------------------- a Mac without a battery
BatteryNoBattery=No Battery
BatteryNoBatteryBody=This Mac doesn’t have a battery.

; ---------------------------------------------------------------- tooltips (the card's is also its accessibility text)
; the card: "<percent>%" + BatteryTipJoin + the state + " " + the health clause
BatteryTipJoin=", "
BatteryTipState0=This Mac doesn’t have a battery.
BatteryTipState1=charging.
BatteryTipState2=charging: [MeasureDuration] until full.
BatteryTipState3=on battery: [MeasureDuration] left.
BatteryTipState4=on battery.
BatteryTipState5=fully charged.
BatteryTipState6=charging paused. The Mac is plugged in but holding its charge, usually to protect the battery.
BatteryTipState7=Low Power Mode is on.
BatteryTipHealth=Health [MeasureHealthText], [MeasureCyclesText] cycles.
; the rows
BatteryTipHealthRow0=Maximum capacity [MeasureHealthShown] of new, as System Settings › Battery shows it.
BatteryTipHealthRow1=Maximum capacity [MeasureHealthShown] of new. macOS recommends having the battery serviced.
BatteryTipCyclesRow=[MeasureCyclesText] charge cycles.
BatteryTipTemperatureRow=Battery temperature [MeasureTempText]°.
BatteryTipPower0=Battery power: no reading yet.
BatteryTipPower1=Charging the battery at [MeasurePowerAbs] W.
BatteryTipPower2=Drawing [MeasurePowerAbs] W from the battery.
BatteryTipPower3=No power is flowing into or out of the battery.
BatteryTipAdapter0=No power adapter is connected.
BatteryTipAdapter1=[MeasureAdapterName], up to [MeasureAdapterText] W.
