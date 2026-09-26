import Foundation
@testable import DesksetCore

func runRoundMeterTests(_ t: TestRunner) {
    let pi = Double.pi

    func roundline(_ skin: Skin, _ name: String) -> RoundlineMeter? { skin.meter(named: name) as? RoundlineMeter }
    func rotator(_ skin: Skin, _ name: String) -> RotatorMeter? { skin.meter(named: name) as? RotatorMeter }

    /// Line end points of a Roundline, or nil when it does not draw a line.
    func line(_ m: RoundlineMeter?) -> (x1: Double, y1: Double, x2: Double, y2: Double, width: Double)? {
        guard case let .line(x1, y1, x2, y2, width)? = m?.shape else { return nil }
        return (x1, y1, x2, y2, width)
    }

    func sector(_ m: RoundlineMeter?) -> (cx: Double, cy: Double, inner: Double, outer: Double,
                                          start: Double, sweep: Double)? {
        guard case let .sector(cx, cy, inner, outer, start, sweep)? = m?.shape else { return nil }
        return (cx, cy, inner, outer, start, sweep)
    }

    t.suite("RoundMeter: fraction and ValueRemainder") {
        func f(_ v: Double, min: Double = 0, max: Double = 100, rem: Double = 0) -> Double {
            RoundMeterMath.fraction(value: v, minValue: min, maxValue: max, valueRemainder: rem)
        }
        t.close(f(30), 0.3)
        t.close(f(150), 1, "clamped above")
        t.close(f(-5), 0, "clamped below")
        t.close(f(15, min: 10, max: 20), 0.5)
        t.close(f(25, min: 100, max: 0), 0.75, "reversed range inverts")
        t.close(f(5, min: 3, max: 3), 0, "empty range")
        t.close(f(5, max: .infinity), 0, "infinite range")
        t.close(f(.nan), 0)
        t.close(f(.infinity), 0)

        // Clock hands on a Windows timestamp (whole days + 10:08:30).
        let day = 86_400.0
        let ts: Double = 152_000 * day + 36_510  // 10:08:30
        t.close(f(ts, max: 1, rem: 60), 0.5, "seconds hand at :30")
        t.close(f(ts, max: 1, rem: 3600), 510.0 / 3600, "minutes hand at 8:30")
        t.close(f(ts, max: 1, rem: 43200), 36_510.0 / 43_200, "hours hand at 10:08:30")
        t.close(f(ts + 7200, max: 1, rem: 43200), 510.0 / 43_200, "12:08:30 wraps to 0:08:30")
        t.close(f(12.5, rem: 10), 0.25, "fractional values keep moving")
        t.close(f(-15, rem: 60), 0.75, "negative values wrap forward")
        t.close(f(75, rem: -60), 0.25, "negative remainder acts like its absolute value")
        t.close(f(30, rem: .infinity), 0.3, "non-finite remainder is off")
        let tiny = f(7, rem: 1e-300)
        t.check(tiny >= 0 && tiny <= 1)
        let huge = f(1e300, rem: 7)
        t.check(huge >= 0 && huge <= 1)
    }

    t.suite("RoundMeter: angle, point and rotator transform math") {
        t.close(RoundMeterMath.angle(startAngle: 1, rotationAngle: 2, fraction: 0.5), 2)
        t.close(RoundMeterMath.angle(startAngle: 1, rotationAngle: 2, fraction: 0.5, controlAngle: false), 1)
        t.close(RoundMeterMath.angle(startAngle: .nan, rotationAngle: 2, fraction: 0.5), 0)

        // Zero angle points right; 3π/2 points up (y grows downward); π/2 points down.
        var p = RoundMeterMath.point(centerX: 50, centerY: 50, radius: 10, angle: 0)
        t.close(p.x, 60); t.close(p.y, 50)
        p = RoundMeterMath.point(centerX: 50, centerY: 50, radius: 10, angle: 3 * pi / 2)
        t.close(p.x, 50, accuracy: 1e-9); t.close(p.y, 40, accuracy: 1e-9)
        p = RoundMeterMath.point(centerX: 50, centerY: 50, radius: 10, angle: pi / 2)
        t.close(p.x, 50, accuracy: 1e-9); t.close(p.y, 60, accuracy: 1e-9)
        p = RoundMeterMath.point(centerX: 50, centerY: 50, radius: -10, angle: 0)
        t.close(p.x, 40, "negative radius lands on the other side")

        let c = RoundMeterMath.center(of: SkinRect(x: 10, y: 20, width: 100, height: 60))
        t.close(c.x, 60); t.close(c.y, 50)

        // The image point (offsetX, offsetY) sits on the center; a positive angle turns clockwise on screen.
        let tr = RoundMeterMath.rotatorTransform(centerX: 100, centerY: 80, angle: pi / 2, offsetX: 20, offsetY: 6)
        var q = tr.apply(x: 20, y: 6)
        t.close(q.x, 100, accuracy: 1e-9); t.close(q.y, 80, accuracy: 1e-9)
        q = tr.apply(x: 30, y: 6)  // 10 px along the (right-pointing) hand → now 10 px below the center
        t.close(q.x, 100, accuracy: 1e-9); t.close(q.y, 90, accuracy: 1e-9)
        q = tr.apply(x: 20, y: 16)  // 10 px "down" in the image → now 10 px left of the center
        t.close(q.x, 90, accuracy: 1e-9); t.close(q.y, 80, accuracy: 1e-9)
        let identity = RoundMeterMath.rotatorTransform(centerX: 5, centerY: 7, angle: 0, offsetX: 0, offsetY: 0)
        t.equal(identity, RoundMeterMath.Transform(a: 1, b: 0, c: -0, d: 1, tx: 5, ty: 7))
    }

    t.suite("RoundMeter: Roundline defaults, center and bound measure") {
        let (skin, _) = try makeSkin(t, """
        [M50]
        Measure=Calc
        Formula=50
        MaxValue=100

        [Box]
        Meter=Roundline
        X=10
        Y=20
        W=100
        H=60
        LineLength=20

        [NoSize]
        Meter=Roundline
        X=30
        Y=40
        LineLength=20

        [Padded]
        Meter=Roundline
        X=0
        Y=0
        W=40
        H=40
        Padding=10,20,0,0
        LineLength=5

        [Bound]
        Meter=Roundline
        MeasureName=M50
        W=100
        H=100
        LineLength=10

        [Missing]
        Meter=Roundline
        MeasureName=NoSuchMeasure
        LineLength=10
        """)
        skin.update()
        let box = roundline(skin, "Box")
        t.check(box != nil)
        t.equal(box?.options.lineColor, RGBA(r: 255, g: 255, b: 255, a: 255), "LineColor default")
        t.close(box?.options.lineWidth ?? -1, 1, "LineWidth default")
        t.close(box?.options.startAngle ?? -1, 0)
        t.close(box?.options.rotationAngle ?? -1, 2 * pi, "RotationAngle defaults to a full turn")
        t.equal(box?.options.solid, false)
        t.equal(box?.options.controlAngle, true)
        t.equal(box?.options.controlStart, false)
        t.equal(box?.options.controlLength, false)
        t.close(box?.fraction ?? -1, 1, "no MeasureName = 100%")
        t.close(box?.center.x ?? -1, 60)
        t.close(box?.center.y ?? -1, 50)
        // 100% of 2π from angle 0: pointing right.
        if let l = line(box) {
            t.close(l.x1, 60, accuracy: 1e-9); t.close(l.y1, 50, accuracy: 1e-9)
            t.close(l.x2, 80, accuracy: 1e-9); t.close(l.y2, 50, accuracy: 1e-9)
            t.close(l.width, 1)
        } else {
            t.check(false, "Box draws a line")
        }

        let noSize = roundline(skin, "NoSize")
        t.equal(noSize?.frame, SkinRect(x: 30, y: 40, width: 0, height: 0), "no W/H: empty box")
        t.close(noSize?.center.x ?? -1, 30, "center at X")
        t.close(noSize?.center.y ?? -1, 40, "center at Y")

        let padded = roundline(skin, "Padded")
        t.close(padded?.center.x ?? -1, 30, "center of the padded content box")
        t.close(padded?.center.y ?? -1, 40)

        t.close(roundline(skin, "Bound")?.fraction ?? -1, 0.5)
        if let l = line(roundline(skin, "Bound")) {
            t.close(l.x2, 40, accuracy: 1e-9, "50% of a full turn from 0 points left")
            t.close(l.y2, 50, accuracy: 1e-9)
        } else {
            t.check(false, "Bound draws a line")
        }
        t.close(roundline(skin, "Missing")?.fraction ?? -1, 1, "unknown measure behaves like no measure")
        t.close(skin.width, 110)
        t.close(skin.height, 100)
    }

    t.suite("RoundMeter: Roundline clock hands from a Time measure") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Now=10:08:30

        [MeasureTime]
        Measure=Time
        TimeStamp=#Now#
        TimeStampFormat=%H:%M:%S

        [StyleHand]
        MeasureName=MeasureTime
        X=0
        Y=0
        W=200
        H=200
        StartAngle=4.7124
        RotationAngle=6.2832

        [Hours]
        Meter=Roundline
        MeterStyle=StyleHand
        ValueRemainder=43200
        LineLength=50

        [Minutes]
        Meter=Roundline
        MeterStyle=StyleHand
        ValueRemainder=3600
        LineStart=-10
        LineLength=80

        [Seconds]
        Meter=Roundline
        MeterStyle=StyleHand
        ValueRemainder=60
        LineLength=90
        LineWidth=2
        """)
        skin.update()
        t.close(roundline(skin, "Seconds")?.fraction ?? -1, 0.5)
        t.close(roundline(skin, "Minutes")?.fraction ?? -1, 510.0 / 3600)
        t.close(roundline(skin, "Hours")?.fraction ?? -1, 36_510.0 / 43_200)

        if let s = line(roundline(skin, "Seconds")) {
            // :30 → straight down (4.7124 + 6.2832 / 2 is 3π/2 + π to 4 decimals).
            t.close(s.x1, 100, accuracy: 1e-9); t.close(s.y1, 100, accuracy: 1e-9)
            t.close(s.x2, 100, accuracy: 0.01); t.close(s.y2, 190, accuracy: 0.01)
            t.close(s.width, 2)
        } else {
            t.check(false, "second hand is a line")
        }
        if let m = line(roundline(skin, "Minutes")) {
            let a = 4.7124 + 6.2832 * 510.0 / 3600
            t.close(m.x2, 100 + 80 * cos(a), accuracy: 1e-9)
            t.close(m.y2, 100 + 80 * sin(a), accuracy: 1e-9)
            t.close(m.x1, 100 - 10 * cos(a), accuracy: 1e-9, "negative LineStart makes a tail")
            t.check(m.x2 > 100 && m.y2 < 100, "8½ minutes points up and right")
        } else {
            t.check(false, "minute hand is a line")
        }
        if let h = line(roundline(skin, "Hours")) {
            t.check(h.x2 < 100 && h.y2 < 100, "10 o'clock points up and left")
            let a = 4.7124 + 6.2832 * 36_510.0 / 43_200
            t.close(h.x2, 100 + 50 * cos(a), accuracy: 1e-9)
            t.close(h.y2, 100 + 50 * sin(a), accuracy: 1e-9)
        } else {
            t.check(false, "hour hand is a line")
        }

        // Time moves on: the hands follow when the measure updates.
        skin.setVariable("Now", "3:00:00")
        skin.perform(Bang(name: "setoption", args: ["MeasureTime", "TimeStamp", "#Now#"]))
        skin.update()
        if let h = line(roundline(skin, "Hours")) {
            t.close(h.x2, 150, accuracy: 0.01, "3 o'clock points right")
            t.close(h.y2, 100, accuracy: 0.01)
        } else {
            t.check(false, "hour hand is a line")
        }
    }

    t.suite("RoundMeter: Roundline LineStart, ControlStart, ControlLength, ControlAngle") {
        let (skin, _) = try makeSkin(t, """
        [M25]
        Measure=Calc
        Formula=25
        MaxValue=100

        [Style]
        MeasureName=M25
        W=100
        H=100

        [Plain]
        Meter=Roundline
        MeterStyle=Style
        LineStart=10
        LineLength=40

        [Reversed]
        Meter=Roundline
        MeterStyle=Style
        LineStart=40
        LineLength=10

        [Length]
        Meter=Roundline
        MeterStyle=Style
        LineLength=20
        ControlLength=1
        LengthShift=40

        [LengthOff]
        Meter=Roundline
        MeterStyle=Style
        LineLength=20
        LengthShift=40

        [Start]
        Meter=Roundline
        MeterStyle=Style
        LineStart=30
        ControlStart=1
        StartShift=-20
        LineLength=45

        [Static]
        Meter=Roundline
        MeterStyle=Style
        ControlAngle=0
        StartAngle=1
        RotationAngle=3
        LineLength=10

        [Ccw]
        Meter=Roundline
        MeterStyle=Style
        RotationAngle=-6.283185307179586
        LineLength=10

        [ZeroWidth]
        Meter=Roundline
        MeterStyle=Style
        LineWidth=0
        LineLength=10

        [ZeroLength]
        Meter=Roundline
        MeterStyle=Style
        LineStart=10
        LineLength=10
        """)
        skin.update()
        // 25% of a full turn from 0 → straight down (π/2).
        if let l = line(roundline(skin, "Plain")) {
            t.close(l.x1, 50, accuracy: 1e-9); t.close(l.y1, 60, accuracy: 1e-9)
            t.close(l.x2, 50, accuracy: 1e-9); t.close(l.y2, 90, accuracy: 1e-9)
        } else { t.check(false, "Plain") }
        if let l = line(roundline(skin, "Reversed")) {
            t.close(l.y1, 90, accuracy: 1e-9, "LineLength is measured from the center, even when < LineStart")
            t.close(l.y2, 60, accuracy: 1e-9)
        } else { t.check(false, "Reversed") }
        if let l = line(roundline(skin, "Length")) {
            t.close(l.y2, 50 + 20 + 40 * 0.25, accuracy: 1e-9, "LineLength + LengthShift × 25%")
        } else { t.check(false, "Length") }
        if let l = line(roundline(skin, "LengthOff")) {
            t.close(l.y2, 70, accuracy: 1e-9, "LengthShift needs ControlLength=1")
        } else { t.check(false, "LengthOff") }
        if let l = line(roundline(skin, "Start")) {
            t.close(l.y1, 50 + 30 - 20 * 0.25, accuracy: 1e-9, "LineStart + StartShift × 25%")
            t.close(l.y2, 95, accuracy: 1e-9)
        } else { t.check(false, "Start") }
        t.close(roundline(skin, "Static")?.angle ?? -1, 1, "ControlAngle=0: static at StartAngle")
        if let l = line(roundline(skin, "Static")) {
            t.close(l.x2, 50 + 10 * cos(1), accuracy: 1e-9)
            t.close(l.y2, 50 + 10 * sin(1), accuracy: 1e-9)
        } else { t.check(false, "Static") }
        if let l = line(roundline(skin, "Ccw")) {
            t.close(l.x2, 50, accuracy: 1e-9); t.close(l.y2, 40, accuracy: 1e-9, "−25% of a turn points up")
        } else { t.check(false, "Ccw") }
        t.equal(roundline(skin, "ZeroWidth")?.shape, RoundlineMeter.Shape.none, "LineWidth=0 draws nothing")
        t.equal(roundline(skin, "ZeroLength")?.shape, RoundlineMeter.Shape.none, "zero-length line draws nothing")
    }

    t.suite("RoundMeter: Roundline Solid pies and rings") {
        let (skin, _) = try makeSkin(t, """
        [M30]
        Measure=Calc
        Formula=30
        MaxValue=100

        [Zero]
        Measure=Calc
        Formula=0
        MaxValue=100

        [Style]
        W=120
        H=120
        Solid=1
        StartAngle=4.712
        RotationAngle=6.283

        [Pie]
        Meter=Roundline
        MeterStyle=Style
        MeasureName=M30
        LineLength=60
        LineWidth=9

        [Ring]
        Meter=Roundline
        MeterStyle=Style
        MeasureName=M30
        LineStart=40
        LineLength=50

        [RingSwapped]
        Meter=Roundline
        MeterStyle=Style
        MeasureName=M30
        LineStart=50
        LineLength=40

        [Ccw]
        Meter=Roundline
        MeterStyle=Style
        MeasureName=M30
        RotationAngle=-6.283
        LineLength=60

        [Disc]
        Meter=Roundline
        MeterStyle=Style
        LineLength=60

        [Empty]
        Meter=Roundline
        MeterStyle=Style
        MeasureName=Zero
        LineLength=60

        [GrowingDisc]
        Meter=Roundline
        MeterStyle=Style
        MeasureName=M30
        ControlAngle=0
        ControlLength=1
        LineLength=10
        LengthShift=100

        [NegativeRadii]
        Meter=Roundline
        MeterStyle=Style
        LineStart=-20
        LineLength=-5
        """)
        skin.update()
        if let s = sector(roundline(skin, "Pie")) {
            t.close(s.cx, 60); t.close(s.cy, 60)
            t.close(s.inner, 0); t.close(s.outer, 60)
            t.close(s.start, 4.712)
            t.close(s.sweep, 6.283 * 0.3, accuracy: 1e-12, "fill from StartAngle to the current percentage")
        } else { t.check(false, "Pie is a sector") }
        if let s = sector(roundline(skin, "Ring")) {
            t.close(s.inner, 40); t.close(s.outer, 50)
        } else { t.check(false, "Ring is a sector") }
        if let s = sector(roundline(skin, "RingSwapped")) {
            t.close(s.inner, 40); t.close(s.outer, 50)
        } else { t.check(false, "RingSwapped is a sector") }
        if let s = sector(roundline(skin, "Ccw")) {
            t.close(s.sweep, -6.283 * 0.3, accuracy: 1e-12, "negative RotationAngle fills counter-clockwise")
        } else { t.check(false, "Ccw is a sector") }
        if let s = sector(roundline(skin, "Disc")) {
            t.close(s.sweep, 6.283, "no measure: 100%")
            t.close(s.outer, 60)
        } else { t.check(false, "Disc is a sector") }
        t.equal(roundline(skin, "Empty")?.shape, RoundlineMeter.Shape.none, "0% fills nothing")
        if let s = sector(roundline(skin, "GrowingDisc")) {
            t.close(s.sweep, 2 * pi, "ControlAngle=0 with Solid fills the whole circle")
            t.close(s.outer, 40, "LineLength + LengthShift × 30%")
        } else { t.check(false, "GrowingDisc is a sector") }
        t.equal(roundline(skin, "NegativeRadii")?.shape, RoundlineMeter.Shape.none, "radii clamp at 0")
    }

    t.suite("RoundMeter: Roundline dynamic variables and !SetOption") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Angle=0

        [Hand]
        Meter=Roundline
        W=100
        H=100
        LineLength=10
        ControlAngle=0
        StartAngle=#Angle#
        DynamicVariables=1

        [Other]
        Meter=Roundline
        W=100
        H=100
        LineLength=10
        ControlAngle=0
        """)
        skin.update()
        t.close(roundline(skin, "Hand")?.angle ?? -1, 0)
        skin.perform(Bang(name: "setvariable", args: ["Angle", "(PI/2)"]))
        skin.update()
        // !SetVariable stores the evaluated formula as text (rounded), hence the tolerance.
        t.close(roundline(skin, "Hand")?.angle ?? -1, pi / 2, accuracy: 1e-4, "dynamic variable")
        skin.perform(Bang(name: "setoption", args: ["Other", "StartAngle", "(PI)"]))
        skin.perform(Bang(name: "setoption", args: ["Other", "LineColor", "10,20,30,40"]))
        skin.perform(Bang(name: "setoption", args: ["Other", "Solid", "1"]))
        skin.update()
        let other = roundline(skin, "Other")
        t.close(other?.options.startAngle ?? -1, pi, accuracy: 1e-9, "!SetOption StartAngle")
        t.equal(other?.lineColor, RGBA(r: 10, g: 20, b: 30, a: 40))
        t.equal(other?.options.solid, true)
    }

    t.suite("RoundMeter: Rotator image, offsets and transform") {
        let (skin, _) = try makeSkin(t, """
        [MeasureSeconds]
        Measure=Calc
        Formula=15

        [Hand]
        Meter=Rotator
        MeasureName=MeasureSeconds
        X=10
        Y=10
        W=110
        H=116
        ImagePath=#@#Images\\
        ImageName=Hand
        OffsetX=3
        OffsetY=4
        StartAngle=4.7124
        RotationAngle=6.2832
        ValueRemainder=60

        [Defaults]
        Meter=Rotator
        X=30
        Y=40
        ImageName=Images\\Arrow.png

        [Existing]
        Meter=Rotator
        ImageName=Images\\NoExtension

        [NoImage]
        Meter=Rotator
        W=10
        H=10
        """, files: ["Root/Sub/Images/NoExtension": "not really an image"])
        skin.update()
        let hand = rotator(skin, "Hand")
        t.check(hand?.imagePath?.hasSuffix("/Root/@Resources/Images/Hand.png") == true,
                "ImagePath + ImageName, .png assumed: \(hand?.imagePath ?? "nil")")
        t.close(hand?.fraction ?? -1, 0.25, "ValueRemainder=60 on 15")
        t.close(hand?.angle ?? -1, 4.7124 + 6.2832 * 0.25, accuracy: 1e-12)
        t.close(hand?.center.x ?? -1, 65)
        t.close(hand?.center.y ?? -1, 68)
        if let tr = hand?.imageTransform {
            let pivot = tr.apply(x: 3, y: 4)
            t.close(pivot.x, 65, accuracy: 1e-9, "offset point lands on the center")
            t.close(pivot.y, 68, accuracy: 1e-9)
            // 15 s → 3 o'clock: the image's +x axis points right again.
            let tip = tr.apply(x: 53, y: 4)
            t.close(tip.x, 115, accuracy: 1e-3); t.close(tip.y, 68, accuracy: 1e-3)
        }

        let defaults = rotator(skin, "Defaults")
        t.check(defaults?.imagePath?.hasSuffix("/Root/Sub/Images/Arrow.png") == true, "relative to the skin folder")
        t.close(defaults?.startAngle ?? -1, 0)
        t.close(defaults?.rotationAngle ?? -1, 2 * pi, "RotationAngle default 2π")
        t.close(defaults?.offsetX ?? -1, 0)
        t.close(defaults?.offsetY ?? -1, 0)
        t.close(defaults?.valueRemainder ?? -1, 0)
        t.close(defaults?.fraction ?? -1, 1)
        t.equal(defaults?.frame, SkinRect(x: 30, y: 40, width: 0, height: 0), "no W/H: no size, even with an image")
        t.close(defaults?.center.x ?? -1, 30, "center of rotation at X")
        t.close(defaults?.center.y ?? -1, 40, "center of rotation at Y")
        t.equal(defaults?.imageProcessing.isIdentity, true)

        t.check(rotator(skin, "Existing")?.imagePath?.hasSuffix("/Images/NoExtension") == true,
                "an existing file without extension is used as is")
        t.equal(rotator(skin, "NoImage")?.imagePath, nil)
    }

    t.suite("RoundMeter: Rotator general image options") {
        let (skin, _) = try makeSkin(t, """
        [Crop]
        Meter=Rotator
        ImageName=a.png
        ImageCrop=-50,-30,100,60,5
        ImageFlip=Both
        ImageRotate=450
        UseExifOrientation=1

        [CropDefaultOrigin]
        Meter=Rotator
        ImageName=a.png
        ImageCrop=1,2,3,4

        [BadCrop]
        Meter=Rotator
        ImageName=a.png
        ImageCrop=0,0,-5,10

        [Tint]
        Meter=Rotator
        ImageName=a.png
        ImageTint=255,128,0,128

        [TintAlpha]
        Meter=Rotator
        ImageName=a.png
        ImageTint=255,128,0,128
        ImageAlpha=51

        [Grey]
        Meter=Rotator
        ImageName=a.png
        Greyscale=1

        [Matrix]
        Meter=Rotator
        ImageName=a.png
        ImageTint=0,0,0
        ImageAlpha=0
        ColorMatrix1=0; 0; 1; 0; 0
        ColorMatrix3=1; 0; 0; 0; 0
        ColorMatrix5=0.5; 0; 0; 0; 1

        [WhiteTint]
        Meter=Rotator
        ImageName=a.png
        ImageTint=255,255,255,255
        ImageAlpha=255
        """)
        skin.update()
        let crop = rotator(skin, "Crop")?.imageProcessing
        t.equal(crop?.crop, RotatorMeter.Crop(x: -50, y: -30, width: 100, height: 60, origin: 5))
        if let r = crop?.crop?.rect(imageWidth: 200, imageHeight: 100) {
            t.equal(r, SkinRect(x: 50, y: 20, width: 100, height: 60), "origin 5 = center")
        }
        let c = RotatorMeter.Crop(x: -10, y: 5, width: 4, height: 4, origin: 2)
        t.equal(c.rect(imageWidth: 40, imageHeight: 30), SkinRect(x: 30, y: 5, width: 4, height: 4), "top right")
        t.equal(RotatorMeter.Crop(x: -10, y: -5, width: 4, height: 4, origin: 3)
                    .rect(imageWidth: 40, imageHeight: 30), SkinRect(x: 30, y: 25, width: 4, height: 4))
        t.equal(RotatorMeter.Crop(x: 1, y: -5, width: 4, height: 4, origin: 4)
                    .rect(imageWidth: 40, imageHeight: 30), SkinRect(x: 1, y: 25, width: 4, height: 4))
        t.equal(crop?.flipHorizontal, true)
        t.equal(crop?.flipVertical, true)
        t.close(crop?.rotateDegrees ?? -1, 90, "ImageRotate normalized")
        t.equal(crop?.useExifOrientation, true)
        t.equal(crop?.isIdentity, false)
        t.equal(rotator(skin, "CropDefaultOrigin")?.imageProcessing.crop,
                RotatorMeter.Crop(x: 1, y: 2, width: 3, height: 4, origin: 1))
        t.equal(rotator(skin, "BadCrop")?.imageProcessing.crop, nil, "non-positive crop size is ignored")

        func m(_ name: String) -> [Double]? { rotator(skin, name)?.imageProcessing.colorMatrix }
        var expected = RotatorMeter.identityMatrix
        expected[0] = 1; expected[6] = 128.0 / 255; expected[12] = 0; expected[18] = 128.0 / 255
        t.equal(m("Tint"), expected, "tint multiplies, tint alpha scales opacity")
        expected[18] = 51.0 / 255
        t.equal(m("TintAlpha"), expected, "ImageAlpha overrides the tint alpha")
        let grey = m("Grey") ?? []
        t.equal(grey.count, 25)
        if grey.count == 25 {
            t.close(grey[0], 0.299); t.close(grey[1], 0.299); t.close(grey[2], 0.299)
            t.close(grey[5], 0.587); t.close(grey[11], 0.114); t.close(grey[18], 1)
        }
        var swap = RotatorMeter.identityMatrix
        swap[0] = 0; swap[2] = 1; swap[10] = 1; swap[12] = 0; swap[20] = 0.5
        t.equal(m("Matrix"), swap, "ColorMatrix overrides ImageTint and ImageAlpha; missing rows stay identity")
        t.equal(m("WhiteTint"), nil, "opaque white tint leaves the image unchanged")

        // Greyscale + tint = recolor (grey first, then multiply).
        let recolor = RotatorMeter.colorMatrix(greyscale: true, tint: RGBA(r: 255, g: 0, b: 0), alpha: nil,
                                               matrixRows: [nil, nil, nil, nil, nil]) ?? []
        t.equal(recolor.count, 25)
        if recolor.count == 25 {
            t.close(recolor[0], 0.299); t.close(recolor[1], 0); t.close(recolor[5], 0.587); t.close(recolor[6], 0)
        }
    }

    t.suite("RoundMeter: TestSkins/Round fixtures load and compute") {
        let testSkins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins")
        func load(_ config: String, _ file: String) throws -> (Skin, FakeHost) {
            let host = FakeHost()
            let url = testSkins.appendingPathComponent(config.replacingOccurrences(of: "\\", with: "/"))
                .appendingPathComponent(file)
            let skin = Skin(config: config, fileURL: url, skinsDirectory: testSkins, system: FakeSystem(), host: host)
            try skin.load()
            return (skin, host)
        }

        let (clock, clockHost) = try load("Round\\AnalogClock", "Fixed.ini")
        clock.update()
        t.equal(clock.issues, [])
        t.check(clockHost.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }.isEmpty, "\(clockHost.logs)")
        t.close(roundline(clock, "MeterHourHand")?.fraction ?? -1, 36_510.0 / 43_200)
        t.close(roundline(clock, "MeterMinuteHand")?.fraction ?? -1, 510.0 / 3600)
        t.close(roundline(clock, "MeterSecondsRing")?.fraction ?? -1, 0.5)
        t.close(rotator(clock, "MeterSecondHand")?.fraction ?? -1, 0.5)
        t.close(roundline(clock, "Tick3")?.angle ?? -1, 0)
        t.close(roundline(clock, "Tick6")?.angle ?? -1, pi / 2, accuracy: 1e-9)
        let hand = rotator(clock, "MeterSecondHand")?.imagePath ?? ""
        t.check(FileManager.default.fileExists(atPath: hand), "second hand image: \(hand)")
        t.close(clock.width, 200)
        t.close(clock.height, 200)

        let (gauges, gaugesHost) = try load("Round\\Gauges", "Gauges.ini")
        gauges.update()
        gauges.update()
        t.equal(gauges.issues, [])
        t.check(gaugesHost.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }.isEmpty,
                "\(gaugesHost.logs)")
        t.close(rotator(gauges, "Spinner")?.fraction ?? -1, 60.0 / 360, "two updates of +30 degrees")
        t.close(rotator(gauges, "GaugeNeedle")?.fraction ?? -1, 0.4)
        for name in ["Spinner", "SpinnerGreen", "GaugeNeedle", "ArrowPlain", "ArrowCrop", "ArrowMatrix"] {
            let path = rotator(gauges, name)?.imagePath ?? ""
            t.check(FileManager.default.fileExists(atPath: path), "\(name) image: \(path)")
        }
    }

    // Review: a plain opacity (ImageAlpha / ImageTint alpha) is applied while drawing, so the processed image the
    // renderer caches does not change when only the opacity does (fades animate ImageAlpha on every update).
    t.suite("RoundMeter: Rotator opacity is split from the cached processing") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Fade=255

        [Plain]
        Meter=Rotator
        ImageName=a.png

        [Alpha]
        Meter=Rotator
        ImageName=a.png
        ImageAlpha=51

        [TintAlpha]
        Meter=Rotator
        ImageName=a.png
        ImageTint=255,255,255,102

        [ColoredTintAlpha]
        Meter=Rotator
        ImageName=a.png
        ImageTint=255,128,0,102

        [GreyAlpha]
        Meter=Rotator
        ImageName=a.png
        Greyscale=1
        ImageAlpha=153

        [Invisible]
        Meter=Rotator
        ImageName=a.png
        ImageAlpha=0

        [MatrixAlphaScale]
        Meter=Rotator
        ImageName=a.png
        ColorMatrix4=0; 0; 0; 0.25; 0

        [MatrixAlphaFromRed]
        Meter=Rotator
        ImageName=a.png
        ColorMatrix1=1; 0; 0; 0.5; 0
        ColorMatrix4=0; 0; 0; 0.5; 0

        [MatrixAlphaOffset]
        Meter=Rotator
        ImageName=a.png
        ColorMatrix4=0; 0; 0; 0.5; 0
        ColorMatrix5=0; 0; 0; 0.1; 1

        [MatrixAlphaBoost]
        Meter=Rotator
        ImageName=a.png
        ColorMatrix4=0; 0; 0; 2; 0

        [Fading]
        Meter=Rotator
        ImageName=a.png
        ImageTint=255,128,0
        ImageAlpha=#Fade#
        ImageFlip=Horizontal
        DynamicVariables=1
        """)
        skin.update()
        func split(_ name: String) -> (processing: RotatorMeter.ImageProcessing, opacity: Double)? {
            rotator(skin, name)?.imageProcessing.opacitySplit
        }
        let plain = split("Plain")
        t.equal(plain?.processing.isIdentity, true)
        t.close(plain?.opacity ?? -1, 1)

        for (name, opacity) in [("Alpha", 51.0 / 255), ("TintAlpha", 102.0 / 255), ("Invisible", 0.0),
                                ("MatrixAlphaScale", 0.25)] {
            let s = split(name)
            t.equal(s?.processing.isIdentity, true, "\(name): nothing left to bake into the image")
            t.close(s?.opacity ?? -1, opacity, accuracy: 1e-12, name)
        }

        var tint = RotatorMeter.identityMatrix
        tint[6] = 128.0 / 255
        tint[12] = 0
        let colored = split("ColoredTintAlpha")
        t.equal(colored?.processing.colorMatrix, tint, "the tint colors stay baked, the tint alpha is split off")
        t.close(colored?.opacity ?? -1, 102.0 / 255, accuracy: 1e-12)

        let grey = split("GreyAlpha")
        t.close(grey?.opacity ?? -1, 153.0 / 255, accuracy: 1e-12)
        if let m = grey?.processing.colorMatrix, m.count == 25 {
            t.close(m[0], 0.299); t.close(m[5], 0.587); t.close(m[10], 0.114); t.close(m[18], 1)
        } else {
            t.check(false, "Greyscale stays baked")
        }

        // Alpha that is not a plain 0…1 scale of the alpha stays in the matrix (drawn at full opacity).
        for name in ["MatrixAlphaFromRed", "MatrixAlphaOffset", "MatrixAlphaBoost"] {
            let s = split(name)
            t.close(s?.opacity ?? -1, 1, name)
            t.equal(s?.processing, rotator(skin, name)?.imageProcessing, "\(name) is unchanged")
        }

        // A fade keeps the same baked processing (the renderer's cache key) for every alpha value.
        let first = split("Fading")
        t.close(first?.opacity ?? -1, 1)
        for alpha in ["200", "127.5", "3", "0"] {
            skin.setVariable("Fade", alpha)
            skin.update()
            let s = split("Fading")
            t.equal(s?.processing, first?.processing, "ImageAlpha=\(alpha): same cached image")
            t.close(s?.opacity ?? -1, (Double(alpha) ?? 0) / 255, accuracy: 1e-12)
        }
        t.equal(first?.processing.flipHorizontal, true)
        t.check(first?.processing.colorMatrix != nil, "the tint is still processed")
    }

    t.suite("RoundMeter: TestSkins/Round/Edges fixture") {
        let testSkins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins")
        let host = FakeHost()
        let skin = Skin(config: "Round\\Edges",
                        fileURL: testSkins.appendingPathComponent("Round/Edges/Edges.ini"),
                        skinsDirectory: testSkins, system: FakeSystem(), host: host)
        try skin.load()
        skin.update()
        t.equal(skin.issues, [])
        t.check(host.logs.filter { $0.hasPrefix("Error") || $0.hasPrefix("Warning") }.isEmpty, "\(host.logs)")

        // No W/H: the center is X,Y and the meter adds nothing to the window.
        t.equal(roundline(skin, "CornerDisc")?.frame, SkinRect(x: 0, y: 0, width: 0, height: 0))
        if let s = sector(roundline(skin, "CornerDisc")) {
            t.close(s.cx, 0); t.close(s.cy, 0); t.close(s.outer, 40)
        } else { t.check(false, "CornerDisc is a disc") }
        let edge = rotator(skin, "EdgeRect")
        t.close(edge?.center.x ?? -1, 60); t.close(edge?.center.y ?? -1, 0)
        if let tr = edge?.imageTransform {
            let topLeft = tr.apply(x: 0, y: 0)
            t.close(topLeft.x, 20, accuracy: 1e-9); t.close(topLeft.y, -20, accuracy: 1e-9, "upper half outside")
        }

        // The manual tip: W = H = the image diagonal, offsets = half the image → the image turns around its own
        // center, which is the center of the box, and its corners stay inside the box.
        let tip = rotator(skin, "TipRect")
        let diagonal = (80.0 * 80 + 40 * 40).squareRoot()
        t.close(tip?.frame.width ?? -1, diagonal, accuracy: 1e-9)
        t.close(tip?.center.x ?? -1, 135 + diagonal / 2, accuracy: 1e-9)
        t.close(tip?.center.y ?? -1, 15 + diagonal / 2, accuracy: 1e-9)
        t.close(tip?.angle ?? -1, pi / 6, accuracy: 1e-12, "30 of MaxValue 360 is 30 degrees")
        if let tip {
            let frame = tip.frame
            let tr = tip.imageTransform
            let middle = tr.apply(x: 40, y: 20)
            t.close(middle.x, tip.center.x, accuracy: 1e-9); t.close(middle.y, tip.center.y, accuracy: 1e-9)
            for (x, y) in [(0.0, 0.0), (80, 0), (80, 40), (0, 40)] {
                let p = tr.apply(x: x, y: y)
                t.check(p.x >= frame.x - 1e-9 && p.x <= frame.maxX + 1e-9 && p.y >= frame.y - 1e-9
                        && p.y <= frame.maxY + 1e-9, "corner (\(x),\(y)) inside the box")
            }
        }

        t.close(rotator(skin, "FadeHalf")?.imageProcessing.opacitySplit.opacity ?? -1, 0.5, accuracy: 1e-12)
        t.equal(rotator(skin, "FadeHalf")?.imageProcessing.opacitySplit.processing.isIdentity, true)
        t.close(rotator(skin, "FadeTint")?.imageProcessing.opacitySplit.opacity ?? -1, 64.0 / 255, accuracy: 1e-12)
        t.close(rotator(skin, "FadeGrey")?.imageProcessing.opacitySplit.opacity ?? -1, 160.0 / 255,
                accuracy: 1e-12)

        t.equal(roundline(skin, "LineAliased")?.antiAlias, false)
        t.equal(roundline(skin, "LineSmooth")?.antiAlias, true)
        if let s = sector(roundline(skin, "RingAliased")) {
            t.close(s.sweep, -0.75 * pi, accuracy: 1e-9, "75% of -180 degrees, counter-clockwise")
        } else { t.check(false, "RingAliased is a ring sector") }
        if let s = sector(roundline(skin, "RingTwoTurns")) {
            t.close(s.sweep, 3 * pi, accuracy: 1e-9, "75% of 4π: more than a full turn")
            t.close(s.inner, 38); t.close(s.outer, 48)
        } else { t.check(false, "RingTwoTurns is a ring") }
        if let s = sector(roundline(skin, "DiscFull")) {
            t.close(s.sweep, 6.283, accuracy: 1e-12)
        } else { t.check(false, "DiscFull is a disc") }

        if let l = line(roundline(skin, "NegativeLength")) {
            t.close(l.x1, 300); t.close(l.y1, 190)
            t.close(l.x2, 260, accuracy: 1e-9, "LineLength=-40 points left"); t.close(l.y2, 190, accuracy: 1e-9)
        } else { t.check(false, "NegativeLength is a line") }
        if let l = line(roundline(skin, "NegativeStart")) {
            t.close(l.y1, 170, accuracy: 1e-9, "LineStart=-20 starts above the center")
            t.close(l.y2, 230, accuracy: 1e-9)
        } else { t.check(false, "NegativeStart is a line") }

        t.close(roundline(skin, "PieRemainder")?.fraction ?? -1, 0.75, "-15 with ValueRemainder=60")
        for name in ["EdgeRect", "TipRect", "FadeFull", "FadeHalf", "FadeTint", "FadeGrey"] {
            let path = rotator(skin, name)?.imagePath ?? ""
            t.check(FileManager.default.fileExists(atPath: path), "\(name) image: \(path)")
        }
        t.check(skin.width >= 480, "the Border meter spans the skin (labels depend on the fake text metrics)")
        t.close(skin.height, 261)
    }

    t.suite("RoundMeter: robustness on hostile values") {
        let (skin, _) = try makeSkin(t, """
        [Huge]
        Measure=Calc
        Formula=1e300

        [Weird]
        Meter=Roundline
        MeasureName=Huge
        W=1e300
        H=-5
        LineStart=1e400
        LineLength=(1/0)
        LineWidth=-3
        StartAngle=1e308
        RotationAngle=abc
        ValueRemainder=1e-320
        StartShift=1e999
        ControlStart=1

        [WeirdSolid]
        Meter=Roundline
        MeasureName=Huge
        Solid=1
        LineLength=1e300
        RotationAngle=1e300
        ValueRemainder=7

        [WeirdRotator]
        Meter=Rotator
        MeasureName=Huge
        ImageName=x
        OffsetX=1e400
        OffsetY=-1e400
        StartAngle=(0/0)
        ImageCrop=1e999,0,1e999,1e999,99
        ImageRotate=1e308
        ColorMatrix1=a;b;c
        ColorMatrix2=1e999;;;;;;;;;;
        ImageAlpha=-40
        """)
        for _ in 0..<3 { skin.update() }
        let weird = roundline(skin, "Weird")
        t.check(weird != nil)
        _ = weird?.shape
        _ = weird?.angle
        t.check(weird.map { $0.options.lineWidth >= 0 } ?? false, "negative LineWidth clamps")
        t.check(weird.map { abs($0.options.lineStart) <= 1_000_000 } ?? false, "LineStart clamped")
        if case let .sector(_, _, inner, outer, start, sweep)? = roundline(skin, "WeirdSolid")?.shape {
            t.check(inner.isFinite && outer.isFinite && start.isFinite && sweep.isFinite)
            t.check(outer <= 1_000_000)
        }
        let r = rotator(skin, "WeirdRotator")
        t.check(r.map { $0.angle.isFinite } ?? false)
        let tr = r?.imageTransform
        t.check([tr?.a, tr?.b, tr?.c, tr?.d, tr?.tx, tr?.ty].allSatisfy { $0?.isFinite == true }, "finite transform")
        t.equal(r?.imageProcessing.crop, nil, "infinite crop values are ignored")
        let matrix = r?.imageProcessing.colorMatrix ?? []
        t.check(matrix.allSatisfy { $0.isFinite }, "finite color matrix")
        t.check((r?.imageProcessing.rotateDegrees ?? .nan).isFinite)
    }

    t.suite("RoundMeter: ValueReminder (the common misspelling) works like ValueRemainder") {
        // Enigma's and Elegant Watch's clocks set only `ValueReminder` and their hands move in Rainmeter.
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Now=10:08:30
        [MeasureTime]
        Measure=Time
        TimeStamp=#Now#
        TimeStampFormat=%H:%M:%S
        [StyleSeconds]
        ValueReminder=60
        [Seconds]
        Meter=Roundline
        MeasureName=MeasureTime
        MeterStyle=StyleSeconds
        W=100
        H=100
        LineLength=40
        [Minutes]
        Meter=Roundline
        MeasureName=MeasureTime
        W=100
        H=100
        ValueReminder=3600
        LineLength=40
        [Both]
        Meter=Roundline
        MeasureName=MeasureTime
        W=100
        H=100
        ValueRemainder=60
        ValueReminder=3600
        LineLength=40
        [Hand]
        Meter=Rotator
        MeasureName=MeasureTime
        ValueReminder=43200
        """)
        skin.update()
        t.close(roundline(skin, "Seconds")?.fraction ?? -1, 0.5, "inherited from a MeterStyle")
        t.close(roundline(skin, "Minutes")?.fraction ?? -1, 510.0 / 3600)
        t.close(roundline(skin, "Both")?.fraction ?? -1, 0.5, "the documented spelling wins")
        t.close(rotator(skin, "Hand")?.fraction ?? -1, 36_510.0 / 43_200)
        t.close(rotator(skin, "Hand")?.valueRemainder ?? -1, 43_200)
        skin.perform(Bang(name: "setoption", args: ["Minutes", "ValueReminder", "60"]))
        skin.update()
        t.close(roundline(skin, "Minutes")?.fraction ?? -1, 0.5, "!SetOption with the misspelling")
    }
}
