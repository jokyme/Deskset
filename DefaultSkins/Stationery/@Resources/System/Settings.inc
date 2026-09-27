; Stationery · System — the widget's options and their defaults. Original work, MIT licensed.
;
; Every System size reads this file first and @Resources/Variables.inc after it, so a choice made in the right-click
; menu (which writes Variables.inc) wins over the default here. The keys start with "System" because Variables.inc is
; shared by the whole suite.

[Variables]
; the Medium's and the Large's fourth ring: GPU (the graphics processor's load) or Swap (memory swapped to disk).
; Without a GPU reading 5 seconds after loading, the ring shows Swap until the widget is loaded again
SystemFourthRing=GPU
; the Large's middle band: History (the CPU over the last 5 minutes) or Cores (the load of every core)
SystemCPUView=History
; the Large's Top Processes: 0 by CPU, 1 by memory (the menu and the segmented control write it)
SystemSortBy=0
; where the numbers come from: Live (this Mac) or Demo (the suite's sample, @Resources/System/*-Demo.inc). Demo is
; for screenshots only; never set it in a released file
SystemSource=Live
