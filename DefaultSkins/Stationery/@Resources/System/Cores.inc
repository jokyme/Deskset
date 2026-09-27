; Stationery · System — the Large's CPU: Cores view, one level per core. Original work, MIT licensed.
; One capsule per core, its level flat-topped inside: the capsule intersected with a rectangle as tall as the load
; (at least 2 pt, so a working core never reads as nothing); a combined shape takes the fill of its first shape.
; Performance cores first, then one empty slot, then the efficiency cores; the width and pitch come from the counts
; (Large.inc), so the last level ends on x 344 on every Mac. One block per core, the same but for its number. Shown
; and updated only in the Cores view.

[MeterP1]
Meter=Shape
X=(16 + 0 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP1:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP1:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (1 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 1#SystemCoreSep#[MeasureP1:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP2]
Meter=Shape
X=(16 + 1 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP2:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP2:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (2 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 2#SystemCoreSep#[MeasureP2:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP3]
Meter=Shape
X=(16 + 2 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP3:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP3:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (3 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 3#SystemCoreSep#[MeasureP3:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP4]
Meter=Shape
X=(16 + 3 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP4:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP4:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (4 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 4#SystemCoreSep#[MeasureP4:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP5]
Meter=Shape
X=(16 + 4 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP5:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP5:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (5 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 5#SystemCoreSep#[MeasureP5:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP6]
Meter=Shape
X=(16 + 5 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP6:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP6:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (6 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 6#SystemCoreSep#[MeasureP6:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP7]
Meter=Shape
X=(16 + 6 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP7:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP7:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (7 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 7#SystemCoreSep#[MeasureP7:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP8]
Meter=Shape
X=(16 + 7 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP8:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP8:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (8 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 8#SystemCoreSep#[MeasureP8:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP9]
Meter=Shape
X=(16 + 8 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP9:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP9:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (9 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 9#SystemCoreSep#[MeasureP9:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP10]
Meter=Shape
X=(16 + 9 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP10:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP10:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (10 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 10#SystemCoreSep#[MeasureP10:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP11]
Meter=Shape
X=(16 + 10 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP11:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP11:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (11 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 11#SystemCoreSep#[MeasureP11:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP12]
Meter=Shape
X=(16 + 11 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP12:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP12:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (12 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 12#SystemCoreSep#[MeasureP12:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP13]
Meter=Shape
X=(16 + 12 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP13:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP13:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (13 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 13#SystemCoreSep#[MeasureP13:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP14]
Meter=Shape
X=(16 + 13 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP14:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP14:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (14 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 14#SystemCoreSep#[MeasureP14:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP15]
Meter=Shape
X=(16 + 14 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP15:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP15:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (15 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 15#SystemCoreSep#[MeasureP15:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP16]
Meter=Shape
X=(16 + 15 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP16:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP16:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (16 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 16#SystemCoreSep#[MeasureP16:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP17]
Meter=Shape
X=(16 + 16 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP17:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP17:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (17 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 17#SystemCoreSep#[MeasureP17:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP18]
Meter=Shape
X=(16 + 17 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP18:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP18:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (18 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 18#SystemCoreSep#[MeasureP18:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP19]
Meter=Shape
X=(16 + 18 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP19:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP19:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (19 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 19#SystemCoreSep#[MeasureP19:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP20]
Meter=Shape
X=(16 + 19 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP20:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP20:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (20 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 20#SystemCoreSep#[MeasureP20:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP21]
Meter=Shape
X=(16 + 20 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP21:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP21:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (21 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 21#SystemCoreSep#[MeasureP21:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP22]
Meter=Shape
X=(16 + 21 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP22:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP22:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (22 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 22#SystemCoreSep#[MeasureP22:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP23]
Meter=Shape
X=(16 + 22 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP23:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP23:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (23 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 23#SystemCoreSep#[MeasureP23:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP24]
Meter=Shape
X=(16 + 23 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP24:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP24:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (24 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 24#SystemCoreSep#[MeasureP24:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP25]
Meter=Shape
X=(16 + 24 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP25:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP25:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (25 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 25#SystemCoreSep#[MeasureP25:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP26]
Meter=Shape
X=(16 + 25 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP26:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP26:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (26 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 26#SystemCoreSep#[MeasureP26:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP27]
Meter=Shape
X=(16 + 26 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP27:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP27:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (27 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 27#SystemCoreSep#[MeasureP27:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP28]
Meter=Shape
X=(16 + 27 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP28:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP28:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (28 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 28#SystemCoreSep#[MeasureP28:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP29]
Meter=Shape
X=(16 + 28 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP29:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP29:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (29 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 29#SystemCoreSep#[MeasureP29:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP30]
Meter=Shape
X=(16 + 29 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP30:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP30:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (30 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 30#SystemCoreSep#[MeasureP30:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP31]
Meter=Shape
X=(16 + 30 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP31:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP31:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (31 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 31#SystemCoreSep#[MeasureP31:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterP32]
Meter=Shape
X=(16 + 31 * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureP32:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureP32:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (32 > [MeasureCoreShownP:]))
ToolTipText=[#SystemCoreP[&MeasureCoreKinds:0]] 32#SystemCoreSep#[MeasureP32:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE1]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 1) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE1:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE1:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (1 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 1#SystemCoreSep#[MeasureE1:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE2]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 2) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE2:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE2:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (2 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 2#SystemCoreSep#[MeasureE2:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE3]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 3) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE3:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE3:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (3 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 3#SystemCoreSep#[MeasureE3:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE4]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 4) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE4:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE4:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (4 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 4#SystemCoreSep#[MeasureE4:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE5]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 5) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE5:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE5:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (5 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 5#SystemCoreSep#[MeasureE5:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE6]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 6) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE6:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE6:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (6 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 6#SystemCoreSep#[MeasureE6:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE7]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 7) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE7:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE7:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (7 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 7#SystemCoreSep#[MeasureE7:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores

[MeterE8]
Meter=Shape
X=(16 + ([MeasureCoreShownP:] + 8) * [MeasureCorePitch:])
Y=182
Shape=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor#,#TrackAlpha# | StrokeWidth 0
Shape2=Rectangle 0,0,[MeasureCoreW:],34,([MeasureCoreW:] / 2) | Fill Color #CPUColor# | StrokeWidth 0
Shape3=Rectangle 0,(34 - Max(2, 0.34 * [MeasureE8:])),[MeasureCoreW:],(Max(2, 0.34 * [MeasureE8:])) | StrokeWidth 0
Shape4=Combine Shape2 | Intersect Shape3
Hidden=((#CoresView# = 0) || (8 > [MeasureCoreShownE:]))
ToolTipText=#SystemCoreE# 8#SystemCoreSep#[MeasureE8:0]%
DynamicVariables=1
UpdateDivider=((#CoresView# = 1) ? 1 : -1)
Group=Cores
