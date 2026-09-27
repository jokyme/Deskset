; Stationery · Spectrum — the sound, and when the bars rest. Original work, MIT licensed.
;
; One AudioLevel parent listens to what the Mac plays (Port=Output), from 40 Hz to 16 kHz; its Band children
; (Bands32.inc, Bands64.inc) are the bars. macOS asks once for System Audio Recording when the widget loads (before
; macOS 14.2 for Screen Recording, and then Deskset must be quit and reopened), and shows its recording indicator in
; the menu bar while Spectrum is loaded. Nothing is recorded or saved.
;
; MeasureMode: 0 live · 1 rest · 2 System Audio Recording refused · 3 Screen Recording needed (macOS 13 to 14.1).
; The widget loads at rest and wakes on the first sound; after 3 s of quiet with nothing playing it rests again. Each
; skin says what a mode shows in its LiveActions, RestActions, NoticeAudioActions and NoticeScreenActions.
;
; The tempo. Until Deskset skips a skin's redraw when nothing changed (E7), a skin that updates 30 times a second is
; drawn 30 times a second, even at rest. So the widget keeps its own Tempo (in its own file): Live, updating every
; 33 ms while the bars move, or Rest, once a second; it rewrites Tempo and refreshes when it changes. AudioDivider is
; every half second when Live and every update when Rest.

[Variables]
; ---------------------------------------------------------------- motion (SpectrumMotion, Variables.inc)
; how fast a bar rises and falls, in ms: Calm falls twice as slowly
FFTAttackFull=20
FFTDecayFull=150
FFTAttackCalm=40
FFTDecayCalm=300
MotionNextFull=Calm
MotionNextCalm=Full
Flip1=0
Flip0=1

; ---------------------------------------------------------------- the tempo (Tempo and TempoLive are in the skin's file)
TickLive=33
TickRest=1000
DefaultDividerLive=30
DefaultDividerRest=1
AudioDividerLive=15
AudioDividerRest=1
SpectrumTick=[#Tick[#Tempo]]
SpectrumDivider=[#DefaultDivider[#Tempo]]
AudioDivider=[#AudioDivider[#Tempo]]
; a change of tempo writes the skin's own file and refreshes it; staying in a tempo does nothing
ToRestLive=[!WriteKeyValue Variables Tempo Rest][!WriteKeyValue Variables TempoLive 0][!Refresh]
ToRestRest=
ToLiveRest=[!WriteKeyValue Variables Tempo Live][!WriteKeyValue Variables TempoLive 1][!Refresh]
ToLiveLive=
ToRestNow=[#ToRest[#Tempo]]
ToLiveNow=[#ToLive[#Tempo]]

; ---------------------------------------------------------------- state
; 1 on macOS 13 to 14.1, where system audio comes through Screen Recording (MeasureOS sets it)
OldCapture=0
; the play button's command at rest: OpenPlayer while the player is closed, PlayPause while it runs
PlayCommand=OpenPlayer
; screenshots only: 0-3 shows that mode whatever the sound does. -1 (always, in a released file): the sound decides
TestMode=-1

; ---------------------------------------------------------------- the sound
[MeasureAudio]
Measure=Plugin
Plugin=AudioLevel
Port=Output
; 4096 samples at 48 kHz: 11.7 Hz apart, so the bass bands (40-48 Hz) resolve; a hop of 1024 (21 ms) gives every
; 33 ms frame a fresh spectrum
FFTSize=4096
FFTOverlap=3072
FFTAttack=[#FFTAttack[#SpectrumMotion]]
FFTDecay=[#FFTDecay[#SpectrumMotion]]
Bands=#Bands#
FreqMin=40
FreqMax=16000
Sensitivity=35
UpdateDivider=#AudioDivider#
Group=Audio

[MeasureRMSL]
Measure=Plugin
Plugin=AudioLevel
Parent=MeasureAudio
Type=RMS
Channel=L
UpdateDivider=#AudioDivider#
Group=Audio

[MeasureRMSR]
Measure=Plugin
Plugin=AudioLevel
Parent=MeasureAudio
Type=RMS
Channel=R
UpdateDivider=#AudioDivider#
Group=Audio

; ---------------------------------------------------------------- a missing permission
[MeasureDevice]
; 1 capturing · 0 not (on macOS 13 to 14.1: Screen Recording missing)
Measure=Plugin
Plugin=AudioLevel
Parent=MeasureAudio
Type=DeviceStatus
UpdateDivider=#AudioDivider#

[MeasureOS]
; "macOS 26.5"
Measure=SysInfo
SysInfoType=OS_VERSION
UpdateDivider=-1
IfMatch=^macOS (13|14\.[01])(\.|$)
IfMatchAction=[!SetVariable OldCapture 1]
IfNotMatchAction=[!SetVariable OldCapture 0]

[MeasureDeviceOff]
; half-seconds without capture: the tap takes a moment to start after load
Measure=Calc
Formula=(MeasureDevice = 0) ? Min(MeasureDeviceOff + 1, 10) : 0
UpdateDivider=#AudioDivider#

[MeasureSilentPlay]
; half-seconds of digital silence while Music or Spotify says it plays: until Deskset tells a refused System Audio
; Recording apart (E27), this is how the widget notices it (it needs Show Track)
Measure=Calc
Formula=((MeasureState = 1) && ((MeasureRMSL + MeasureRMSR) = 0) && (MeasureDevice = 1)) ? Min(MeasureSilentPlay + 1, 100) : 0
UpdateDivider=#AudioDivider#

[MeasureNoticeKind]
; 0 none · 1 System Audio Recording refused (DeviceStatus 2 once Deskset reports it, E27) · 2 Screen Recording needed
Measure=Calc
Formula=((MeasureDevice = 2) || (MeasureSilentPlay >= 20)) ? 1 : (((MeasureDeviceOff >= 4) && (#OldCapture# = 1)) ? 2 : 0)
DynamicVariables=1
UpdateDivider=#AudioDivider#

; ---------------------------------------------------------------- rest and wake
[MeasureHeard]
; 1 once any sound or a playing track has been seen since load (a skin refreshed into the Live tempo has heard it)
Measure=Calc
Formula=(#TempoLive# = 1) || (MeasureHeard = 1) || ((MeasureRMSL + MeasureRMSR) > 0.003) || (MeasureState = 1)
UpdateDivider=#AudioDivider#

[MeasureQuiet]
; half-seconds of quiet (under about -56 dBFS for left and right together) with nothing playing
Measure=Calc
Formula=(((MeasureRMSL + MeasureRMSR) > 0.003) || (MeasureState = 1)) ? 0 : Min(MeasureQuiet + 1, 100)
UpdateDivider=#AudioDivider#

[MeasureMode]
; 0 live · 1 rest · 2 and 3 the Notices; each mode's actions run once, when it begins
Measure=Calc
Formula=(#TestMode# >= 0) ? #TestMode# : ((MeasureNoticeKind > 0) ? (1 + MeasureNoticeKind) : ((MeasureHeard = 0) || (MeasureQuiet >= 6)))
UpdateDivider=#AudioDivider#
IfCondition=MeasureMode = 0
IfTrueAction=#LiveActions#
IfCondition2=MeasureMode = 1
IfTrueAction2=#RestActions#
IfCondition3=MeasureMode = 2
IfTrueAction3=#NoticeAudioActions#
IfCondition4=MeasureMode = 3
IfTrueAction4=#NoticeScreenActions#
