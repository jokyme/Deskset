; Stationery · Storage — the widget's options and their defaults. Original work, MIT licensed.
;
; Every Storage size reads this file first and @Resources/Variables.inc after it, so a choice made in the right-click
; menu (which writes Variables.inc) wins over the default here. The keys start with "Storage" because Variables.inc
; is shared by the whole suite.

[Variables]
; the Small's volume: its folder name in /Volumes (empty: the startup disk), and its name as Finder shows it, kept
; for when the disk is not connected. The Small's "Volume: …" menu item writes both
StorageSmallVolume=
StorageSmallVolumeName=
; where the numbers come from: Live (this Mac's disks) or Demo (the suite's sample, @Resources/Storage/Source-Demo.inc).
; Demo is for screenshots only; never set it in a released file
StorageSource=Live
