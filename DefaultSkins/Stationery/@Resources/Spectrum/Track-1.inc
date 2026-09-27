; Stationery · Spectrum — the track's name, from Music or Spotify (Show Track: On). Original work, MIT licensed.
;
; Reading the players is what makes macOS ask for Automation, the first time Spectrum sees one of them running.
; Show Track: Off loads Track-0.inc instead: the same measure names, and no player is ever read.

[Variables]
OpenAction=[!CommandMeasure MeasureTitle "OpenPlayer"]

[MeasureTitle]
; the main measure: every command goes here
Measure=NowPlaying
PlayerName=#Player#
PlayerType=Title
Group=Player

[MeasureArtist]
Measure=NowPlaying
PlayerName=[MeasureTitle]
PlayerType=Artist
Group=Player

[MeasureState]
; 0 stopped, 1 playing, 2 paused
Measure=NowPlaying
PlayerName=[MeasureTitle]
PlayerType=State
Group=Player

[MeasureStatus]
; 1 while the player runs
Measure=NowPlaying
PlayerName=[MeasureTitle]
PlayerType=Status
Group=Player

[MeasureTrackText]
; "Gymnopédie No. 1 · Erik Satie" (a missing title or artist leaves no dangling dot); a new track runs the widget's
; TrackChangedActions
Measure=String
String=[MeasureTitle] · [MeasureArtist]
DynamicVariables=1
RegExpSubstitute=1
Substitute="^ · (.*)$":"\1","^(.*) · $":"\1"
Group=Player
OnChangeAction=#TrackChangedActions#
