; Stationery · Timer — its words in English. Original work, MIT licensed.
; Strings-Chinese.inc has the same keys. A value with a space at either end is quoted, or the INI reader would trim it.

[Variables]
TimerTitle=Timer
; "Ends at 10:17" (%1 is the end, in the Mac's 12- or 24-hour clock)
TimerEndsAt=Ends at %1
TimerReset=Reset
TimerDone=Done
; after a preset's number in its tooltip ("5 minutes")
TimerMinutesUnit=" minutes"
; the menu
TimerMenuMinutes=Minutes…
TimerMenuReset=Reset Timer
TimerMenuSound1=Sound: On
TimerMenuSound0=Sound: Off
; the ring's tooltip by state: ready, running (Pause), paused, done
TimerTipStart0=Start
TimerTipStart1=Start
TimerTipStart2=Resume
TimerTipStart3=Start Again
TimerTipPause=Pause
TimerTipReset=Reset
; the card's sentence by state: \1 the minutes, \2 the time left, \3 the end
TimerTipReady=\1-minute timer, ready. Scroll to change the minutes.
TimerTipRunning=\1-minute timer: \2 left, ends at \3.
TimerTipPaused=\1-minute timer, paused with \2 left.
TimerTipDone=\1-minute timer, done at \3.
