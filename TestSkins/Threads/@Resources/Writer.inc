; Writer fixture (original content), included by Writer/A.ini … D.ini: at every update each copy writes a new key into
; one shared file (@Resources/Counts.inc), named after its own file, its load and its update count. The "threads"
; stress suite runs the four copies on four threads at once and sets StressLoad to the number of each load, so no key
; is ever written twice: a read-modify-write that is not done under one lock loses keys of the other skins
; (docs/skin-threading.md §4.10, IniWriter's per-file lock). The suite runs a copy; rendering a writer in place adds
; its keys to the Counts.inc of the repository.
[Rainmeter]
Update=1000
OnUpdateAction=[!WriteKeyValue Counts "#CURRENTFILE# [MeasureLoad]-[MeasureCount]" "[MeasureCount]" "#@#Counts.inc"]

[Metadata]
Name=Writer
Author=Deskset
License=Original test fixture

[Variables]
StressLoad=1

[MeasureLoad]
Measure=String
String=#StressLoad#
DynamicVariables=1

[MeasureCount]
Measure=Calc
Formula=Counter

[Count]
Meter=String
MeasureName=MeasureCount
Text=#CURRENTFILE# wrote %1
FontSize=10
FontColor=255,255,255,255
SolidColor=0,0,0,160
AntiAlias=1
