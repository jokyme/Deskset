; Stationery · Sentence Clock — the English words. Original work, MIT licensed.
;
; A language is one file like this one: a Lit measure (0 or 1) and a String meter per word, and the sentence as text
; for the tooltip. The 33 words sit in 8 rows, each justified to 26 → 334 at 19 pt (SF Pro Semibold, 1.4 pt apart),
; and every sentence the grammar makes, for all 1440 minutes, reads in grid order: left to right, top to bottom. A
; word with two roles is two meters (the minute FIVE and the hour FIVE). X and Y are the meter frames, Padding
; included: the text starts at X + 14 and its baseline is at Y + 12 + 18.37 (rows 36 apart, from 40.39).
;
; The part of the day goes by the hour the sentence names: 1–11 morning, 13–17 afternoon, 18–21 evening, 22–23 night;
; noon and midnight take none ("It's nearly midnight", "It's a quarter past noon").
; ---------------------------------------------------------------- which words are lit
[LitIts]
Measure=Calc
Formula=1
Group=Sentence
UpdateDivider=-1

[LitNearly]
Measure=Calc
Formula=MeasureRem >= 3
Group=Sentence
UpdateDivider=-1

[LitJust]
Measure=Calc
Formula=(MeasureRem >= 1) && (MeasureRem <= 2)
Group=Sentence
UpdateDivider=-1

[LitAfter]
Measure=Calc
Formula=(MeasureRem >= 1) && (MeasureRem <= 2)
Group=Sentence
UpdateDivider=-1

[LitA]
Measure=Calc
Formula=MeasureDist = 3
Group=Sentence
UpdateDivider=-1

[LitQuarter]
Measure=Calc
Formula=MeasureDist = 3
Group=Sentence
UpdateDivider=-1

[LitHalf]
Measure=Calc
Formula=MeasureDist = 6
Group=Sentence
UpdateDivider=-1

[LitTwenty]
Measure=Calc
Formula=(MeasureDist = 4) || (MeasureDist = 5)
Group=Sentence
UpdateDivider=-1

[LitFiveM]
Measure=Calc
Formula=(MeasureDist = 1) || (MeasureDist = 5)
Group=Sentence
UpdateDivider=-1

[LitTenM]
Measure=Calc
Formula=MeasureDist = 2
Group=Sentence
UpdateDivider=-1

[LitPast]
Measure=Calc
Formula=(MeasureSlot >= 1) && (MeasureSlot <= 6)
Group=Sentence
UpdateDivider=-1

[LitTo]
Measure=Calc
Formula=MeasureSlot >= 7
Group=Sentence
UpdateDivider=-1

[LitH3]
Measure=Calc
Formula=(MeasureHour % 12) = 3
Group=Sentence
UpdateDivider=-1

[LitH1]
Measure=Calc
Formula=(MeasureHour % 12) = 1
Group=Sentence
UpdateDivider=-1

[LitH2]
Measure=Calc
Formula=(MeasureHour % 12) = 2
Group=Sentence
UpdateDivider=-1

[LitH4]
Measure=Calc
Formula=(MeasureHour % 12) = 4
Group=Sentence
UpdateDivider=-1

[LitMidnight]
Measure=Calc
Formula=MeasureHour = 0
Group=Sentence
UpdateDivider=-1

[LitH5]
Measure=Calc
Formula=(MeasureHour % 12) = 5
Group=Sentence
UpdateDivider=-1

[LitH6]
Measure=Calc
Formula=(MeasureHour % 12) = 6
Group=Sentence
UpdateDivider=-1

[LitH7]
Measure=Calc
Formula=(MeasureHour % 12) = 7
Group=Sentence
UpdateDivider=-1

[LitH9]
Measure=Calc
Formula=(MeasureHour % 12) = 9
Group=Sentence
UpdateDivider=-1

[LitH10]
Measure=Calc
Formula=(MeasureHour % 12) = 10
Group=Sentence
UpdateDivider=-1

[LitH8]
Measure=Calc
Formula=(MeasureHour % 12) = 8
Group=Sentence
UpdateDivider=-1

[LitH11]
Measure=Calc
Formula=(MeasureHour % 12) = 11
Group=Sentence
UpdateDivider=-1

[LitOClock]
Measure=Calc
Formula=(MeasureSlot = 0) && ((MeasureHour % 12) <> 0)
Group=Sentence
UpdateDivider=-1

[LitIn]
Measure=Calc
Formula=((MeasureHour % 12) <> 0) && (MeasureHour <= 21)
Group=Sentence
UpdateDivider=-1

[LitThe]
Measure=Calc
Formula=((MeasureHour % 12) <> 0) && (MeasureHour <= 21)
Group=Sentence
UpdateDivider=-1

[LitMorning]
Measure=Calc
Formula=(MeasureHour >= 1) && (MeasureHour <= 11)
Group=Sentence
UpdateDivider=-1

[LitAfternoon]
Measure=Calc
Formula=(MeasureHour >= 13) && (MeasureHour <= 17)
Group=Sentence
UpdateDivider=-1

[LitNoon]
Measure=Calc
Formula=MeasureHour = 12
Group=Sentence
UpdateDivider=-1

[LitEvening]
Measure=Calc
Formula=(MeasureHour >= 18) && (MeasureHour <= 21)
Group=Sentence
UpdateDivider=-1

[LitAt]
Measure=Calc
Formula=MeasureHour >= 22
Group=Sentence
UpdateDivider=-1

[LitNight]
Measure=Calc
Formula=MeasureHour >= 22
Group=Sentence
UpdateDivider=-1

[MeasureSentence]
; the lit words read in grid order: "It’s nearly ten past ten in the morning"
Measure=String
String=|[LitIts:]It’s|[LitNearly:]nearly|[LitJust:]just|[LitAfter:]after|[LitA:]a|[LitQuarter:]quarter|[LitHalf:]half|[LitTwenty:]twenty|[LitFiveM:]five|[LitTenM:]ten|[LitPast:]past|[LitTo:]to|[LitH3:]three|[LitH1:]one|[LitH2:]two|[LitH4:]four|[LitMidnight:]midnight|[LitH5:]five|[LitH6:]six|[LitH7:]seven|[LitH9:]nine|[LitH10:]ten|[LitH8:]eight|[LitH11:]eleven|[LitOClock:]o’clock|[LitIn:]in|[LitThe:]the|[LitMorning:]morning|[LitAfternoon:]afternoon|[LitNoon:]noon|[LitEvening:]evening|[LitAt:]at|[LitNight:]night
RegExpSubstitute=1
Substitute="\|0[^|]*":"","\|1(?:\.0+)?":" ","^ ":""
DynamicVariables=1
Group=Sentence
UpdateDivider=-1

; ---------------------------------------------------------------- the words, row by row
[wIts]
Meter=String
MeterStyle=sWord
X=12.00
Y=10.02
Text=IT’S
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitIts:])

[wNearly]
Meter=String
MeterStyle=sWord
X=75.41
Y=10.02
Text=NEARLY
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitNearly:])

[wJust]
Meter=String
MeterStyle=sWord
X=178.66
Y=10.02
Text=JUST
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitJust:])

[wAfter]
Meter=String
MeterStyle=sWord
X=255.47
Y=10.02
Text=AFTER
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitAfter:])

[wA]
Meter=String
MeterStyle=sWord
X=12.00
Y=46.02
Text=A
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitA:])

[wQuarter]
Meter=String
MeterStyle=sWord
X=44.71
Y=46.02
Text=QUARTER
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitQuarter:])

[wHalf]
Meter=String
MeterStyle=sWord
X=161.25
Y=46.02
Text=HALF
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitHalf:])

[wTwenty]
Meter=String
MeterStyle=sWord
X=233.45
Y=46.02
Text=TWENTY
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitTwenty:])

[wFiveM]
Meter=String
MeterStyle=sWord
X=12.00
Y=82.02
Text=FIVE
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitFiveM:])

[wTenM]
Meter=String
MeterStyle=sWord
X=75.79
Y=82.02
Text=TEN
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitTenM:])

[wPast]
Meter=String
MeterStyle=sWord
X=135.21
Y=82.02
Text=PAST
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitPast:])

[wTo]
Meter=String
MeterStyle=sWord
X=207.10
Y=82.02
Text=TO
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitTo:])

[wH3]
Meter=String
MeterStyle=sWord
X=253.94
Y=82.02
Text=THREE
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH3:])

[wH1]
Meter=String
MeterStyle=sWord
X=12.00
Y=118.02
Text=ONE
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH1:])

[wH2]
Meter=String
MeterStyle=sWord
X=74.13
Y=118.02
Text=TWO
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH2:])

[wH4]
Meter=String
MeterStyle=sWord
X=140.95
Y=118.02
Text=FOUR
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH4:])

[wMidnight]
Meter=String
MeterStyle=sWord
X=216.27
Y=118.02
Text=MIDNIGHT
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitMidnight:])

[wH5]
Meter=String
MeterStyle=sWord
X=12.00
Y=154.02
Text=FIVE
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH5:])

[wH6]
Meter=String
MeterStyle=sWord
X=75.12
Y=154.02
Text=SIX
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH6:])

[wH7]
Meter=String
MeterStyle=sWord
X=127.27
Y=154.02
Text=SEVEN
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH7:])

[wH9]
Meter=String
MeterStyle=sWord
X=213.01
Y=154.02
Text=NINE
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH9:])

[wH10]
Meter=String
MeterStyle=sWord
X=280.40
Y=154.02
Text=TEN
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH10:])

[wH8]
Meter=String
MeterStyle=sWord
X=12.00
Y=190.02
Text=EIGHT
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH8:])

[wH11]
Meter=String
MeterStyle=sWord
X=92.43
Y=190.02
Text=ELEVEN
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitH11:])

[wOClock]
Meter=String
MeterStyle=sWord
X=188.90
Y=190.02
Text=O’CLOCK
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitOClock:])

[wIn]
Meter=String
MeterStyle=sWord
X=299.55
Y=190.02
Text=IN
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitIn:])

[wThe]
Meter=String
MeterStyle=sWord
X=12.00
Y=226.02
Text=THE
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitThe:])

[wMorning]
Meter=String
MeterStyle=sWord
X=73.44
Y=226.02
Text=MORNING
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitMorning:])

[wAfternoon]
Meter=String
MeterStyle=sWord
X=193.44
Y=226.02
Text=AFTERNOON
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitAfternoon:])

[wNoon]
Meter=String
MeterStyle=sWord
X=12.00
Y=262.02
Text=NOON
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitNoon:])

[wEvening]
Meter=String
MeterStyle=sWord
X=95.32
Y=262.02
Text=EVENING
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitEvening:])

[wAt]
Meter=String
MeterStyle=sWord
X=208.25
Y=262.02
Text=AT
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitAt:])

[wNight]
Meter=String
MeterStyle=sWord
X=255.63
Y=262.02
Text=NIGHT
FontColor=#InkRGB#,(#OffNow# + (#OnA# - #OffNow#) * [LitNight:])
