import Foundation
@testable import DesksetCore

/// FakeHost that also answers the optional image queries (EXIF orientation, pixel alpha).
private final class ImageQueryHost: FakeHost, SkinImageQueries {
    var orientations: [String: Int] = [:]
    /// Alpha by (file name, x, y); nil = unknown.
    var alpha: ((String, Int, Int) -> Double?)?
    var alphaQueries: [(Int, Int)] = []

    func imageExifOrientation(atPath path: String) -> Int {
        orientations[(path as NSString).lastPathComponent] ?? 1
    }

    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        alphaQueries.append((x, y))
        return alpha?((path as NSString).lastPathComponent, x, y)
    }
}

private func imageMeter(_ skin: Skin, _ name: String) -> ImageMeter {
    skin.meter(named: name) as! ImageMeter
}

func runImageMeterTests(_ t: TestRunner) {
    t.suite("ImageMeter: file names, ImagePath, MeasureName and %N") {
        let host = FakeHost()
        host.imageSizes = ["Card.png": (120, 80)]
        let (skin, _) = try makeSkin(t, """
        [MeasureName]
        Measure=String
        String=Card
        [MeasureName2]
        Measure=String
        String=Night
        [MeasureNumber]
        Measure=Calc
        Formula=12.5

        [Plain]
        Meter=Image
        ImageName=Card.png
        [NoExtension]
        Meter=Image
        ImageName=Card
        [Resources]
        Meter=Image
        ImageName=#@#Images\\Card
        [WithImagePath]
        Meter=Image
        ImagePath=#@#Images\\
        ImageName=Card.jpg
        [DeprecatedPath]
        Meter=Image
        Path=#@#Old
        ImageName=Card
        [Absolute]
        Meter=Image
        ImageName=/tmp/Deskset/Card.PNG
        [Quoted]
        Meter=Image
        ImageName="Card.gif"
        [Measure]
        Meter=Image
        MeasureName=MeasureName
        [MeasureOverridesName]
        Meter=Image
        MeasureName=MeasureName
        ImageName=Other.png
        [Template]
        Meter=Image
        MeasureName=MeasureName
        MeasureName2=MeasureName2
        ImageName=%1-%2.jpg
        [Number]
        Meter=Image
        MeasureName=MeasureNumber
        [Weird]
        Meter=Image
        ImageName=sunny.day
        [Existing]
        Meter=Image
        ImageName=real.name
        [Empty]
        Meter=Image
        W=10
        H=10
        SolidColor=255,0,0
        """, files: ["Root/Sub/real.name": "x"], host: host)
        skin.update()
        func path(_ n: String) -> String { imageMeter(skin, n).imagePath ?? "nil" }
        t.check(path("Plain").hasSuffix("/Root/Sub/Card.png"), path("Plain"))
        t.check(path("NoExtension").hasSuffix("/Root/Sub/Card.png"), path("NoExtension"))
        t.check(path("Resources").hasSuffix("/Root/@Resources/Images/Card.png"), path("Resources"))
        t.check(path("WithImagePath").hasSuffix("/Root/@Resources/Images/Card.jpg"), path("WithImagePath"))
        t.check(path("DeprecatedPath").hasSuffix("/Root/@Resources/Old/Card.png"), path("DeprecatedPath"))
        t.equal(path("Absolute"), "/tmp/Deskset/Card.PNG")
        t.check(path("Quoted").hasSuffix("/Root/Sub/Card.gif"), path("Quoted"))
        t.check(path("Measure").hasSuffix("/Root/Sub/Card.png"), path("Measure"))
        t.check(path("MeasureOverridesName").hasSuffix("/Root/Sub/Card.png"), path("MeasureOverridesName"))
        t.check(path("Template").hasSuffix("/Root/Sub/Card-Night.jpg"), path("Template"))
        t.check(path("Number").hasSuffix("/Root/Sub/12.5.png"), path("Number"))
        t.check(path("Weird").hasSuffix("/Root/Sub/sunny.day.png"), path("Weird"))
        t.check(path("Existing").hasSuffix("/Root/Sub/real.name"), path("Existing"))
        t.equal(imageMeter(skin, "Empty").imagePath, nil)
        t.equal(imageMeter(skin, "Plain").frame, SkinRect(x: 0, y: 0, width: 120, height: 80))
        t.equal(imageMeter(skin, "Empty").frame, SkinRect(x: 0, y: 0, width: 10, height: 10))
        t.check(host.logs.contains { $0.contains("Unable to open image") && $0.contains("Night") },
                "missing image logged")

        // !SetOption changes the file; the size follows.
        skin.execute("[!SetOption Plain ImageName \"Wide100x50.png\"]", from: nil)
        skin.update()
        t.check(path("Plain").hasSuffix("/Root/Sub/Wide100x50.png"), path("Plain"))
        t.equal(imageMeter(skin, "Plain").frame.width, 100)
    }

    t.suite("ImageMeter: size with W/H, PreserveAspectRatio, crop, rotate and tile") {
        let host = FakeHost()
        host.imageSizes = ["Card.png": (120, 80)]
        let (skin, _) = try makeSkin(t, """
        [Style]
        ImageName=Card.png
        [Natural]
        Meter=Image
        MeterStyle=Style
        [Both]
        Meter=Image
        MeterStyle=Style
        W=30
        H=90
        [OnlyW]
        Meter=Image
        MeterStyle=Style
        W=60
        [OnlyH]
        Meter=Image
        MeterStyle=Style
        H=40
        [OnlyWPar0]
        Meter=Image
        MeterStyle=Style
        W=60
        PreserveAspectRatio=0
        [OnlyWPar2]
        Meter=Image
        MeterStyle=Style
        W=60
        PreserveAspectRatio=2
        [OnlyWTile]
        Meter=Image
        MeterStyle=Style
        W=300
        Tile=1
        [CropCenter]
        Meter=Image
        MeterStyle=Style
        ImageCrop=-30,-20,60,40,5
        [Rotate90]
        Meter=Image
        MeterStyle=Style
        ImageRotate=90
        [Rotate45]
        Meter=Image
        MeterStyle=Style
        ImageRotate=-45
        [CropRotate]
        Meter=Image
        MeterStyle=Style
        ImageCrop=0,0,(5*4),10
        ImageRotate=270
        [RotateOnlyH]
        Meter=Image
        MeterStyle=Style
        ImageRotate=90
        H=60
        [Padded]
        Meter=Image
        MeterStyle=Style
        W=60
        Padding=1,2,3,4
        [Missing]
        Meter=Image
        ImageName=Nope.png
        W=25
        """, host: host)
        skin.update()
        func size(_ n: String) -> [Double] {
            let f = imageMeter(skin, n).frame
            return [f.width, f.height]
        }
        t.equal(size("Natural"), [120, 80])
        t.equal(size("Both"), [30, 90])
        t.equal(imageMeter(skin, "Both").preserveAspectRatio, 0)
        t.equal(size("OnlyW"), [60, 40])
        t.equal(imageMeter(skin, "OnlyW").preserveAspectRatio, 1, "only one of W/H → PAR defaults to 1")
        t.equal(size("OnlyH"), [60, 40])
        t.equal(size("OnlyWPar0"), [60, 80], "explicit PAR=0 keeps the natural height")
        t.equal(size("OnlyWPar2"), [60, 40])
        t.equal(size("OnlyWTile"), [300, 80], "Tile does not scale")
        t.equal(size("CropCenter"), [60, 40])
        t.equal(size("Rotate90"), [80, 120])
        let r45 = imageMeter(skin, "Rotate45").frame
        t.close(r45.width, 200 / 2.0.squareRoot(), accuracy: 1e-6)
        t.close(r45.height, 200 / 2.0.squareRoot(), accuracy: 1e-6)
        t.equal(size("CropRotate"), [10, 20])
        t.equal(size("RotateOnlyH"), [40, 60])
        t.equal(size("Padded"), [64, 46])
        t.equal(imageMeter(skin, "Padded").contentFrame, SkinRect(x: 1, y: 2, width: 60, height: 40))
        t.equal(size("Missing"), [25, 0])

        // Legacy accessors.
        let c = imageMeter(skin, "CropCenter")
        t.equal(c.imageCrop ?? [], [-30, -20, 60, 40, 5])
        t.close(imageMeter(skin, "Rotate90").imageRotate, 90)
        t.equal(c.imageTint, nil)
        t.close(c.imageAlpha, 255)
    }

    t.suite("ImageMeter: ImageCrop origins") {
        func crop(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ origin: Int) -> SkinRect {
            ImageOptions.Crop(x: x, y: y, width: w, height: h, origin: origin).rect(imageWidth: 200, imageHeight: 100)
        }
        t.equal(crop(10, 5, 50, 20, 1), SkinRect(x: 10, y: 5, width: 50, height: 20))
        t.equal(crop(-50, 0, 50, 20, 2), SkinRect(x: 150, y: 0, width: 50, height: 20))
        t.equal(crop(-50, -20, 50, 20, 3), SkinRect(x: 150, y: 80, width: 50, height: 20))
        t.equal(crop(0, -20, 50, 20, 4), SkinRect(x: 0, y: 80, width: 50, height: 20))
        t.equal(crop(-50, -30, 100, 60, 5), SkinRect(x: 50, y: 20, width: 100, height: 60), "manual example")
        t.equal(crop(0, 0, -5, 1e300, 1), SkinRect(x: 0, y: 0, width: 0, height: ImageOptions.maxSide))
        t.equal(crop(1.4, 1.6, 10.5, 9.4, 9), SkinRect(x: 1, y: 2, width: 11, height: 9), "rounded; bad origin = 1")
    }

    t.suite("ImageMeter: image options parsing and colors") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Half=0.5
        [Tinted]
        Meter=Image
        ImageTint=255,128,0,100
        Greyscale=1
        ImageFlip=Both
        ImageRotate=370
        UseExifOrientation=1
        ImageCrop=(5*2), 0, 20, 30, 3
        [AlphaOverride]
        Meter=Image
        ImageTint=255,255,255,60
        ImageAlpha=200
        [Matrix]
        Meter=Image
        ColorMatrix1=0;0;1;0;0
        ColorMatrix3=1; 0; 0
        ColorMatrix5=(#Half#);0;0;0;1
        ImageAlpha=10
        [Prefixed]
        Meter=Image
        PrimaryImageTint=0,0,255
        PrimaryImageFlip=Vertical
        PrimaryColorMatrix4=0;0;0;0.5;0
        BothImageColorMatrix1=0;1;0;0;0
        PrimaryImagePath=#@#Primary
        [Garbage]
        Meter=Image
        ImageTint=nonsense
        ImageAlpha=-40
        ImageFlip=sideways
        ImageRotate=(1/0)
        ImageCrop=1,2
        ColorMatrix2=a;b;c
        """)
        skin.update()
        let o = imageMeter(skin, "Tinted").imageOptions
        t.equal(o.tint, RGBA(r: 255, g: 128, b: 0, a: 100))
        t.check(o.greyscale)
        t.equal(o.flip, .both)
        t.close(o.rotate, 10)
        t.check(o.useExifOrientation)
        t.equal(o.crop, ImageOptions.Crop(x: 10, y: 0, width: 20, height: 30, origin: 3))
        t.close(o.drawAlpha, 100, "tint alpha")
        // Greyscale then tint: a pure red pixel becomes 0.299 grey times the tint.
        let red = ImageOptions.apply(o.processingMatrix ?? [], r: 1, g: 0, b: 0, a: 1)
        t.close(red.r, 0.299, accuracy: 1e-9)
        t.close(red.g, 0.299 * 128 / 255, accuracy: 1e-9)
        t.close(red.b, 0, accuracy: 1e-9)
        t.close(red.a, 1)

        let a = imageMeter(skin, "AlphaOverride").imageOptions
        t.close(a.drawAlpha, 200, "ImageAlpha overrides the tint alpha")
        t.equal(a.processingMatrix, nil, "white tint and no greyscale leave colors alone")

        let m = imageMeter(skin, "Matrix").imageOptions
        t.close(m.drawAlpha, 255, "ColorMatrix overrides ImageAlpha")
        let px = ImageOptions.apply(m.processingMatrix ?? [], r: 0.2, g: 0.4, b: 0.6, a: 0.8)
        // Row 1 sends red to blue, row 3 (partial: 1;0;0 then identity 0;0) sends blue to red, row 5 adds 0.5 red.
        t.close(px.r, 1, accuracy: 1e-9, "0.6 + 0.5, clamped")
        t.close(px.g, 0.4, accuracy: 1e-9)
        t.close(px.b, 0.2, accuracy: 1e-9)
        t.close(px.a, 0.8, accuracy: 1e-9)

        let p = ImageOptions.read(from: imageMeter(skin, "Prefixed"), prefix: "Primary")
        t.equal(p.tint, RGBA(r: 0, g: 0, b: 255))
        t.equal(p.flip, .vertical)
        t.close(p.colorMatrix?[18] ?? -1, 0.5)
        t.check(ImageOptions.imagePathOption(imageMeter(skin, "Prefixed"), prefix: "Primary").hasSuffix("@Resources/Primary"))
        let both = ImageOptions.read(from: imageMeter(skin, "Prefixed"), prefix: "Both", colorMatrixKey: "BothImageColorMatrix")
        t.close(both.colorMatrix?[1] ?? -1, 1)

        let g = imageMeter(skin, "Garbage").imageOptions
        t.equal(g.tint, .white)
        t.close(g.alpha ?? -1, 0)
        t.equal(g.flip, .none)
        t.close(g.rotate, 0)
        t.equal(g.crop, nil)
        t.equal(g.colorMatrix?[5 ... 9].map { $0 } ?? [], [0, 0, 0, 0, 0], "unreadable values read as 0")
        t.check(skin.meter(named: "Garbage") != nil)
    }

    t.suite("ImageMeter: color matrix math") {
        var o = ImageOptions()
        t.equal(o.processingMatrix, nil)
        o.tint = RGBA(r: 255, g: 255, b: 255, a: 10)
        t.equal(o.processingMatrix, nil, "alpha of the tint is applied when drawing")
        t.close(o.drawAlpha, 10)
        o.colorMatrix = ImageOptions.identityMatrix
        t.equal(o.processingMatrix, nil, "identity matrix = no processing")
        t.close(o.drawAlpha, 255)
        // Invert (ColorMatrix guide).
        o.colorMatrix = [-1, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1]
        let inv = ImageOptions.apply(o.processingMatrix ?? [], r: 0.25, g: 1, b: 0, a: 0.5)
        t.close(inv.r, 0.75)
        t.close(inv.g, 0)
        t.close(inv.b, 1)
        t.close(inv.a, 0.5)
        // White to alpha.
        o.colorMatrix = [1, 0, 0, -1, 0, 0, 1, 0, -1, 0, 0, 0, 1, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1]
        t.close(ImageOptions.apply(o.processingMatrix ?? [], r: 1, g: 1, b: 1, a: 1).a, 0)
        t.close(ImageOptions.apply(o.processingMatrix ?? [], r: 0.1, g: 0.2, b: 0.3, a: 1).a, 0.4, accuracy: 1e-9)
        // Greyscale is applied before the matrix.
        o.greyscale = true
        o.colorMatrix = nil
        o.tint = .white
        let grey = ImageOptions.apply(o.processingMatrix ?? [], r: 0, g: 1, b: 0, a: 1)
        t.close(grey.r, 0.587, accuracy: 1e-9)
        t.close(grey.b, 0.587, accuracy: 1e-9)
        let product = ImageOptions.multiply(ImageOptions.identityMatrix, [Double](repeating: 2, count: 25))
        t.equal(product, [Double](repeating: 2, count: 25))
        t.equal(ImageOptions.multiply([1], [2]), ImageOptions.identityMatrix, "bad sizes do not crash")
    }

    t.suite("ImageMeter: placement, nine-slice and strips") {
        let bounds = SkinRect(x: 10, y: 20, width: 100, height: 100)
        t.equal(ImageGeometry.placement(imageWidth: 200, imageHeight: 100, in: bounds, preserveAspectRatio: 0), bounds)
        t.equal(ImageGeometry.placement(imageWidth: 200, imageHeight: 100, in: bounds, preserveAspectRatio: 1),
                SkinRect(x: 10, y: 45, width: 100, height: 50))
        t.equal(ImageGeometry.placement(imageWidth: 200, imageHeight: 100, in: bounds, preserveAspectRatio: 2),
                SkinRect(x: -40, y: 20, width: 200, height: 100))
        t.equal(ImageGeometry.placement(imageWidth: 0, imageHeight: 100, in: bounds, preserveAspectRatio: 1), bounds)

        let pieces = ImageGeometry.nineSlice(imageWidth: 30, imageHeight: 30,
                                             margins: SkinInsets(left: 10, top: 5, right: 10, bottom: 5),
                                             into: SkinRect(x: 0, y: 0, width: 100, height: 50))
        t.equal(pieces.count, 9)
        t.equal(pieces.first?.source, SkinRect(x: 0, y: 0, width: 10, height: 5))
        t.equal(pieces.first?.destination, SkinRect(x: 0, y: 0, width: 10, height: 5))
        t.equal(pieces[4].source, SkinRect(x: 10, y: 5, width: 10, height: 20))
        t.equal(pieces[4].destination, SkinRect(x: 10, y: 5, width: 80, height: 40))
        t.equal(pieces[8].destination, SkinRect(x: 90, y: 45, width: 10, height: 5))
        // Destination smaller than the margins: they shrink proportionally, no center.
        let small = ImageGeometry.nineSlice(imageWidth: 30, imageHeight: 30,
                                            margins: SkinInsets(left: 10, top: 10, right: 10, bottom: 10),
                                            into: SkinRect(x: 0, y: 0, width: 10, height: 40))
        t.equal(small.map(\.destination.width).reduce(0, max), 5)
        t.check(small.allSatisfy { $0.destination.maxX <= 10 })
        // Margins wider than the image.
        let wide = ImageGeometry.nineSlice(imageWidth: 10, imageHeight: 10,
                                           margins: SkinInsets(left: 30, top: 0, right: 10, bottom: 0),
                                           into: SkinRect(x: 0, y: 0, width: 100, height: 10))
        t.equal(wide.map(\.source.width), [7.5, 2.5])
        t.equal(ImageGeometry.nineSlice(imageWidth: 10, imageHeight: 10,
                                        margins: SkinInsets(left: .nan, top: -1, right: .infinity, bottom: 0),
                                        into: SkinRect(x: 0, y: 0, width: 10, height: 10)).count, 1)

        let h = ImageGeometry.stripFrames(imageWidth: 120, imageHeight: 18, count: 10)
        t.check(h.horizontal)
        t.equal([h.width, h.height], [12, 18])
        let v = ImageGeometry.stripFrames(imageWidth: 40, imageHeight: 60, count: 5)
        t.check(!v.horizontal)
        t.equal([v.width, v.height], [40, 12])
        t.equal(ImageGeometry.stripFrameRect(index: 3, frameWidth: 40, frameHeight: 12, horizontal: false),
                SkinRect(x: 0, y: 36, width: 40, height: 12))
        t.equal(ImageOptions.rotatedSize(width: 10, height: 20, degrees: -270).width, 20)
        t.equal(ImageOptions.rotatedSize(width: 10, height: 20, degrees: .nan).width, 0)
    }

    t.suite("ImageMeter: EXIF orientation and masks") {
        let host = ImageQueryHost()
        host.imageSizes = ["Photo.jpg": (80, 120), "Mask.png": (64, 32), "Card.png": (120, 80)]
        host.orientations = ["Photo.jpg": 6]
        let (skin, _) = try makeSkin(t, """
        [Raw]
        Meter=Image
        ImageName=Photo.jpg
        [Oriented]
        Meter=Image
        ImageName=Photo.jpg
        UseExifOrientation=1
        [OrientedCrop]
        Meter=Image
        ImageName=Photo.jpg
        UseExifOrientation=1
        ImageCrop=-10,0,10,5,2
        [Masked]
        Meter=Image
        ImagePath=#@#Primary
        ImageName=Card.png
        MaskImageName=Mask
        MaskImagePath=#@#Masks
        [MaskedSized]
        Meter=Image
        ImageName=Card.png
        MaskImageName=Mask.png
        MaskImageRotate=90
        MaskImageFlip=Horizontal
        W=100
        [MaskedNoImagePath]
        Meter=Image
        ImagePath=#@#Primary
        ImageName=Card.png
        MaskImageName=Mask.png
        Tile=1
        """, host: host)
        skin.update()
        t.equal(imageMeter(skin, "Raw").frame.width, 80)
        t.equal(imageMeter(skin, "Oriented").frame, SkinRect(x: 0, y: 0, width: 120, height: 80))
        t.equal(imageMeter(skin, "OrientedCrop").frame.width, 10)
        let masked = imageMeter(skin, "Masked")
        t.check(masked.maskImagePath?.hasSuffix("/Root/@Resources/Masks/Mask.png") == true, masked.maskImagePath ?? "")
        t.equal(masked.frame, SkinRect(x: 0, y: 0, width: 64, height: 32), "the mask defines the size")
        let sized = imageMeter(skin, "MaskedSized")
        t.equal(sized.maskOptions.flip, .horizontal)
        t.close(sized.maskOptions.rotate, 90)
        t.equal(sized.frame, SkinRect(x: 0, y: 0, width: 100, height: 200), "rotated mask 32x64, only W")
        t.equal(sized.imageDestination()?.width, 300, "the image fills the mask area")
        let noPath = imageMeter(skin, "MaskedNoImagePath")
        t.check(noPath.maskImagePath?.hasSuffix("/Root/Sub/Mask.png") == true, "ImagePath is not used for the mask")
        t.check(noPath.imagePath?.hasSuffix("/Root/@Resources/Primary/Card.png") == true)
    }

    t.suite("ImageMeter: Bar colors, orientation, flip and BarImage") {
        let host = FakeHost()
        host.imageSizes = ["BarH.png": (100, 12), "BarV.png": (12, 60)]
        let (skin, _) = try makeSkin(t, """
        [M37]
        Measure=Calc
        Formula=37
        MaxValue=100
        [M999]
        Measure=Calc
        Formula=999
        MaxValue=100
        [Default]
        Meter=Bar
        MeasureName=M37
        W=10
        H=100
        [Horizontal]
        Meter=Bar
        MeasureName=M37
        W=100
        H=10
        BarOrientation=horizontal
        BarColor=FF000080
        [HorizontalFlip]
        Meter=Bar
        MeasureName=M37
        X=5
        Y=5
        W=100
        H=10
        BarOrientation=Horizontal
        Flip=1
        [VerticalFlip]
        Meter=Bar
        MeasureName=M999
        W=10
        H=100
        Flip=1
        [Image]
        Meter=Bar
        MeasureName=M37
        X=10
        Y=20
        ImagePath=#@#Bars
        BarImage=BarV
        BarBorder=4
        [ImageH]
        Meter=Bar
        MeasureName=M37
        BarImage=BarH.png
        BarOrientation=Horizontal
        BarBorder=3
        Flip=1
        W=200
        H=40
        [Unbound]
        Meter=Bar
        W=10
        H=10
        BarBorder=-5
        """, host: host)
        skin.update()
        func bar(_ n: String) -> BarMeter { skin.meter(named: n) as! BarMeter }
        t.equal(bar("Default").barColor, RGBA(r: 0, g: 128, b: 0), "manual default 0,128,0")
        t.check(bar("Default").vertical)
        t.close(bar("Default").fraction, 0.37)
        t.equal(bar("Default").visibleBarRects(), [SkinRect(x: 0, y: 63, width: 10, height: 37)])
        t.equal(bar("Horizontal").barColor, RGBA(r: 255, g: 0, b: 0, a: 128))
        t.equal(bar("Horizontal").visibleBarRects(), [SkinRect(x: 0, y: 0, width: 37, height: 10)])
        t.equal(bar("HorizontalFlip").visibleBarRects(), [SkinRect(x: 68, y: 5, width: 37, height: 10)])
        t.equal(bar("VerticalFlip").visibleBarRects(), [SkinRect(x: 0, y: 0, width: 10, height: 100)])
        t.close(bar("VerticalFlip").fraction, 1)

        let image = bar("Image")
        t.check(image.barImagePath?.hasSuffix("/Root/@Resources/Bars/BarV.png") == true, image.barImagePath ?? "")
        t.equal(image.frame, SkinRect(x: 10, y: 20, width: 12, height: 60), "natural size = image")
        t.equal(image.barImageRect(), SkinRect(x: 10, y: 20, width: 12, height: 60))
        // Border 4 at both ends always drawn; 37% of the 52 px between them = 19 px from the bottom.
        t.equal(image.visibleBarRects(), [SkinRect(x: 10, y: 20, width: 12, height: 4),
                                          SkinRect(x: 10, y: 76, width: 12, height: 4),
                                          SkinRect(x: 10, y: 57, width: 12, height: 19)])
        let imageH = bar("ImageH")
        t.equal(imageH.frame.width, 200, "W/H size the meter, not the image")
        t.equal(imageH.barImageRect(), SkinRect(x: 0, y: 0, width: 100, height: 12))
        t.equal(imageH.visibleBarRects().last, SkinRect(x: 97 - 34, y: 0, width: 34, height: 12))
        t.close(bar("Unbound").fraction, 0)
        t.close(bar("Unbound").barBorder, 0)
        t.equal(bar("Unbound").visibleBarRects(), [])

        t.equal(BarMeter.barRects(area: SkinRect(x: 0, y: 0, width: 10, height: 10), fraction: 0.5, vertical: true,
                                  flip: false, border: 50),
                [SkinRect(x: 0, y: 0, width: 10, height: 5), SkinRect(x: 0, y: 5, width: 10, height: 5)],
                "a border bigger than the bar covers it")
        t.equal(BarMeter.barRects(area: SkinRect(x: 0, y: 0, width: 100, height: 1), fraction: 0.29,
                                  vertical: false, flip: false, border: 0).first?.width, 29)
        t.equal(BarMeter.barRects(area: SkinRect(x: 0, y: 0, width: 100, height: 1), fraction: .nan,
                                  vertical: false, flip: false, border: 0), [])
    }

    t.suite("ImageMeter: Bitmap frames, extend, digits and align") {
        let host = FakeHost()
        host.imageSizes = ["Level.png": (40, 60), "Digits.png": (120, 18), "Trans.png": (360, 18)]
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        TransitionUpdate=50
        [P]
        Measure=Calc
        Formula=0
        MinValue=0
        MaxValue=100
        DynamicVariables=1
        [V]
        Measure=Calc
        Formula=42
        [Level]
        Meter=Bitmap
        MeasureName=P
        BitmapImage=Level.png
        BitmapFrames=5
        X=5
        Y=5
        W=999
        H=999
        [Zero]
        Meter=Bitmap
        MeasureName=P
        BitmapImage=Level.png
        BitmapFrames=5
        BitmapZeroFrame=1
        [Digits]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=10
        BitmapExtend=1
        [Fixed]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=10
        BitmapExtend=1
        BitmapDigits=4
        BitmapSeparation=3
        X=100
        [Right]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=10
        BitmapExtend=1
        BitmapAlign=Right
        X=100
        Y=30
        [Center]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=10
        BitmapExtend=1
        BitmapAlign=Center
        X=100
        Y=60
        [Trans]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Trans.png
        BitmapFrames=30
        BitmapTransitionFrames=2
        BitmapExtend=1
        """, host: host)
        func bitmap(_ n: String) -> BitmapMeter { skin.meter(named: n) as! BitmapMeter }
        let cases: [(Double, Int, Int)] = [(0, 0, 0), (19, 0, 1), (20, 1, 1), (39.9, 1, 2), (40, 2, 2), (99, 4, 4),
                                            (100, 4, 4), (-5, 0, 0), (250, 4, 4), (1, 0, 1), (25, 1, 1), (26, 1, 2)]
        for (value, frame, zeroFrame) in cases {
            skin.execute("[!SetOption P Formula \(value)]", from: nil)
            skin.update()
            t.equal(bitmap("Level").displayedFrames, [frame], "value \(value)")
            t.equal(bitmap("Zero").displayedFrames, [zeroFrame], "zero frame, value \(value)")
        }
        let level = bitmap("Level")
        t.equal(level.frame, SkinRect(x: 5, y: 5, width: 40, height: 12), "W/H ignored; one vertical frame")
        t.equal(level.cells().first?.source, SkinRect(x: 0, y: 12, width: 40, height: 12), "26% → frame 1")

        t.equal(bitmap("Digits").displayedFrames, [4, 2])
        t.equal(bitmap("Digits").frame, SkinRect(x: 0, y: 0, width: 24, height: 18))
        t.equal(bitmap("Digits").cells().map(\.source.x), [48, 24])
        t.equal(bitmap("Fixed").displayedFrames, [0, 0, 4, 2])
        t.equal(bitmap("Fixed").frame.width, 4 * 12 + 3 * 3)
        t.equal(bitmap("Fixed").cells().map(\.destination.x), [100, 115, 130, 145])
        t.equal(bitmap("Right").frame, SkinRect(x: 76, y: 30, width: 24, height: 18))
        t.equal(bitmap("Center").frame, SkinRect(x: 88, y: 60, width: 24, height: 18))

        // Transitions: 42 → 43 plays the frames after "2" (7, 8), then shows "3" (9).
        let trans = bitmap("Trans")
        t.equal(trans.realFrames, 10)
        t.equal(trans.displayedFrames, [12, 6])
        skin.execute("[!SetOption V Formula 43][!UpdateMeasure V]", from: nil)
        skin.update()
        t.equal(trans.displayedFrames, [12, 7])
        let redraws = host.redraws
        trans.advanceTransition()
        t.equal(trans.displayedFrames, [12, 8])
        trans.advanceTransition()
        t.equal(trans.displayedFrames, [12, 9])
        t.equal(host.redraws, redraws + 2)
        trans.advanceTransition()
        t.equal(trans.displayedFrames, [12, 9], "idle")
        // A new value mid-transition finishes the running one first.
        skin.execute("[!SetOption V Formula 45]", from: nil)
        skin.update()
        t.equal(trans.displayedFrames, [12, 10])
        skin.execute("[!SetOption V Formula 46]", from: nil)
        skin.update()
        t.equal(trans.displayedFrames, [12, 16])
        skin.execute("[!SetOption V Formula 460]", from: nil)
        skin.update()
        t.equal(trans.displayedFrames, [12, 18, 0], "digit count change: no transition")
    }

    t.suite("ImageMeter: Bitmap extend edge values") {
        let host = FakeHost()
        host.imageSizes = ["Digits.png": (120, 18), "One.png": (10, 10), "Odd.png": (25, 7)]
        let (skin, _) = try makeSkin(t, """
        [V]
        Measure=Calc
        Formula=0
        [B]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=10
        BitmapExtend=1
        [Base8]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=8
        BitmapExtend=1
        [Single]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=One.png
        BitmapExtend=1
        BitmapDigits=3
        [Crazy]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Odd.png
        BitmapFrames=(1e20)
        BitmapTransitionFrames=-4
        BitmapDigits=1e9
        BitmapSeparation=-1e300
        BitmapZeroFrame=1
        BitmapExtend=1
        [NoImage]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Missing.png
        BitmapFrames=0
        """, host: host)
        func frames(_ n: String) -> [Int] { (skin.meter(named: n) as! BitmapMeter).displayedFrames }
        func digits(_ v: UInt64, _ radix: Int) -> [Int] { String(v, radix: radix).compactMap { $0.wholeNumberValue } }
        let big = UInt64(BitmapMeter.maxValue)
        let values: [(String, [Int], [Int])] = [
            ("0", [0], [0]), ("9", [9], [1, 1]), ("10", [1, 0], [1, 2]), ("-305.6", [3, 0, 6], [4, 6, 2]),
            ("0.5", [1], [1]), ("(1e30)", digits(big, 10), digits(big, 8)), ("(-1e300)", digits(big, 10), digits(big, 8))]
        for (formula, decimal, octal) in values {
            skin.execute("[!SetOption V Formula \"\(formula)\"]", from: nil)
            skin.update()
            t.equal(frames("B"), decimal, formula)
            t.equal(frames("Base8"), octal, "base 8: \(formula)")
            t.equal(frames("Single"), [0, 0, 0])
        }
        let crazy = skin.meter(named: "Crazy") as! BitmapMeter
        t.equal(crazy.frames, 1, "an out-of-range BitmapFrames reads as the default")
        t.equal(crazy.transitionFrames, 0)
        t.equal(crazy.digits, BitmapMeter.maxDigits)
        t.equal(crazy.displayedFrames.count, BitmapMeter.maxDigits)
        t.check(crazy.frame.width >= 0)
        let none = skin.meter(named: "NoImage") as! BitmapMeter
        t.equal(none.frames, 1)
        t.equal(none.frame.width, 0)
        t.equal(none.cells().count, 0)
    }

    t.suite("ImageMeter: Button states, ButtonCommand and transparent pixels") {
        let host = ImageQueryHost()
        host.imageSizes = ["Button.png": (144, 24), "Tall.png": (20, 90)]
        // Transparent corners: the top-left 4×4 pixels of every frame.
        host.alpha = { _, x, y in (x % 48) < 4 && y < 4 ? 0 : 255 }
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Clicks=0
        [Behind]
        Meter=Image
        W=200
        H=200
        LeftMouseUpAction=[!SetVariable Behind 1]
        [Button]
        Meter=Button
        ButtonImage=Button.png
        ButtonCommand=[!SetVariable Clicks "(#Clicks#+1)"]
        X=10
        Y=10
        W=500
        [Own]
        Meter=Button
        ButtonImage=Button.png
        ButtonCommand=[!SetVariable OwnCommand 1]
        LeftMouseUpAction=[!SetVariable OwnAction 1]
        X=10
        Y=50
        ImageFlip=Horizontal
        [Tall]
        Meter=Button
        ButtonImage=Tall.png
        X=100
        Y=100
        """, host: host)
        skin.update()
        let button = skin.meter(named: "Button") as! ButtonMeter
        t.equal(button.frame, SkinRect(x: 10, y: 10, width: 48, height: 24), "one frame; W ignored")
        t.equal(button.state, .normal)
        t.equal(button.sourceRect(for: .hover), SkinRect(x: 96, y: 0, width: 48, height: 24))
        let tall = skin.meter(named: "Tall") as! ButtonMeter
        t.equal(tall.frame, SkinRect(x: 100, y: 100, width: 20, height: 30))
        t.equal(tall.sourceRect(for: .pressed), SkinRect(x: 0, y: 30, width: 20, height: 30))

        var redraws = host.redraws
        skin.mouseMoved(x: 20, y: 20)
        t.equal(button.state, .hover)
        t.equal(host.redraws, redraws + 1, "state change redraws")
        skin.mouseMoved(x: 21, y: 21)
        t.equal(host.redraws, redraws + 1, "no redraw without a change")
        skin.mouseMoved(x: 11, y: 11)
        t.equal(button.state, .normal, "transparent pixel is not hover")

        // Click: press and release on opaque pixels.
        t.check(skin.mouseEvent(.leftDown, x: 30, y: 20))
        t.equal(button.state, .pressed)
        t.check(skin.mouseEvent(.leftUp, x: 31, y: 21))
        t.equal(skin.variable("Clicks"), "1")
        t.equal(button.state, .hover)
        t.equal(skin.variable("Behind"), nil, "consumed by the button")

        // Press, release outside: no command, back to normal.
        skin.mouseEvent(.leftDown, x: 30, y: 20)
        skin.mouseEvent(.leftUp, x: 150, y: 150)
        t.equal(skin.variable("Clicks"), "1")
        skin.mouseMoved(x: 150, y: 150)
        t.equal(button.state, .normal)
        t.equal(skin.variable("Behind"), "1", "the release went to the meter behind")
        skin.setVariable("Behind", "")

        // Clicks on transparent pixels fall through.
        t.check(skin.mouseEvent(.leftDown, x: 11, y: 11) == false || button.state != .pressed)
        skin.mouseEvent(.leftUp, x: 11, y: 11)
        t.equal(skin.variable("Clicks"), "1")
        t.equal(skin.variable("Behind"), "1")

        // Release without a press does nothing.
        skin.mouseEvent(.leftUp, x: 30, y: 20)
        t.equal(skin.variable("Clicks"), "1")

        // A hover update ends a press whose release was lost.
        skin.mouseEvent(.leftDown, x: 30, y: 20)
        skin.mouseMoved(x: 30, y: 20)
        t.equal(button.state, .hover)
        skin.mouseEvent(.leftUp, x: 30, y: 20)
        t.equal(skin.variable("Clicks"), "1")
        skin.mouseExited()
        t.equal(button.state, .normal)

        // The meter's own LeftMouseUpAction runs too; flipped frames are hit-tested mirrored.
        let own = skin.meter(named: "Own") as! ButtonMeter
        host.alphaQueries = []
        redraws = host.redraws
        skin.mouseEvent(.leftDown, x: 10, y: 50)
        t.equal(host.alphaQueries.first.map { [$0.0, $0.1] } ?? [], [47, 0], "ImageFlip=Horizontal mirrors hit tests")
        t.equal(own.state, .pressed)
        skin.mouseEvent(.leftUp, x: 12, y: 52)
        t.equal(skin.variable("OwnCommand"), "1")
        t.equal(skin.variable("OwnAction"), "1")
        t.check(host.redraws > redraws)
    }

    t.suite("ImageMeter: Button without pixel queries and hidden buttons") {
        let host = FakeHost()
        host.imageSizes = ["Button.png": (144, 24)]
        let (skin, _) = try makeSkin(t, """
        [Button]
        Meter=Button
        ButtonImage=Button.png
        ButtonCommand=[!SetVariable Clicked 1]
        [Hidden]
        Meter=Button
        ButtonImage=Button.png
        ButtonCommand=[!SetVariable HiddenClicked 1]
        Hidden=1
        Y=30
        [NoImage]
        Meter=Button
        ButtonImage=Missing.png
        ButtonCommand=[!SetVariable NoImage 1]
        Y=60
        """, host: host)
        skin.update()
        skin.mouseEvent(.leftDown, x: 0, y: 0)
        skin.mouseEvent(.leftUp, x: 1, y: 1)
        t.equal(skin.variable("Clicked"), "1", "unknown alpha counts as opaque")
        skin.mouseEvent(.leftDown, x: 5, y: 35)
        skin.mouseEvent(.leftUp, x: 5, y: 35)
        t.equal(skin.variable("HiddenClicked"), nil)
        skin.mouseEvent(.leftDown, x: 0, y: 60)
        skin.mouseEvent(.leftUp, x: 0, y: 60)
        t.equal(skin.variable("NoImage"), nil)
        let noImage = skin.meter(named: "NoImage") as! ButtonMeter
        t.equal(noImage.frame.width, 0)
        t.equal(noImage.sourceRect(for: .normal), nil)
    }

    t.suite("ImageMeter: hostile values do not crash") {
        let host = FakeHost()
        host.imageSizes = ["A.png": (10, 10), "Huge.png": (1e12, 1e-12), "Zero.png": (0, 0)]
        let (skin, _) = try makeSkin(t, """
        [M]
        Measure=Calc
        Formula=1e308*10
        [I1]
        Meter=Image
        ImageName=A.png
        ImageCrop=1e300,-1e300,1e300,(0/0),1e300
        ImageRotate=1e300
        W=-5
        PreserveAspectRatio=1e20
        ScaleMargins=-1,-1,-1,-1
        [I2]
        Meter=Image
        ImageName=Huge.png
        ImageRotate=33
        H=10
        [I3]
        Meter=Image
        ImageName=Zero.png
        W=10
        [I4]
        Meter=Image
        MeasureName=M
        ImageName=%1%1%1%2%10
        [Bar1]
        Meter=Bar
        MeasureName=M
        BarImage=Huge.png
        BarBorder=(1/0)
        [Bmp]
        Meter=Bitmap
        MeasureName=M
        BitmapImage=Huge.png
        BitmapExtend=1
        BitmapFrames=3
        [Btn]
        Meter=Button
        ButtonImage=Zero.png
        """, host: host)
        for _ in 0..<3 { skin.update() }
        skin.mouseMoved(x: 1, y: 1)
        skin.mouseEvent(.leftDown, x: 1, y: 1)
        skin.mouseEvent(.leftUp, x: 1, y: 1)
        for meter in skin.meters {
            let f = meter.frame
            t.check(f.width.isFinite && f.height.isFinite && f.width >= 0 && f.height >= 0,
                    "\(meter.name) frame \(f)")
        }
        t.equal(imageMeter(skin, "I1").preserveAspectRatio, 2)
        t.equal(imageMeter(skin, "I1").scaleMargins, nil)
        t.check(skin.width.isFinite && skin.height.isFinite)
    }

    runImageMeterReviewTests(t)
}

// MARK: - Adversarial review probes

func runImageMeterReviewTests(_ t: TestRunner) {
    t.suite("ImageMeter review: button hit test is stable when frames differ in shape") {
        let host = ImageQueryHost()
        // 3 frames of 40×20 side by side. Normal (x 0…39): opaque everywhere. Pressed (x 40…79): drawn 2 px lower
        // (rows 0…1 transparent), as the Button Images tip suggests for a button that "moves" when clicked.
        // Hover (x 80…119): a smaller shape, columns 0…9 of the frame transparent.
        host.imageSizes = ["Shift.png": (120, 20)]
        host.alpha = { _, x, y in
            switch x / 40 {
            case 1: return y < 2 ? 0 : 255
            case 2: return x % 40 < 10 ? 0 : 255
            default: return 255
            }
        }
        let (skin, _) = try makeSkin(t, """
        [Button]
        Meter=Button
        ButtonImage=Shift.png
        ButtonCommand=[!SetVariable Clicks "(#Clicks#+1)"]
        [Variables]
        Clicks=0
        """, host: host)
        skin.update()
        let button = skin.meter(named: "Button") as! ButtonMeter
        // (5, 10) is opaque in the normal frame only: hovering there must not flip state on every mouse move.
        var states: [ButtonMeter.State] = []
        for _ in 0..<4 {
            skin.mouseMoved(x: 5, y: 10)
            states.append(button.state)
        }
        t.equal(Set(states).count, 1, "state depends on the position only: \(states)")
        let redraws = host.redraws
        skin.mouseMoved(x: 5, y: 10)
        skin.mouseMoved(x: 5, y: 10)
        t.equal(host.redraws, redraws, "no redraw while the mouse stays on the same pixel")

        // A click without moving on a pixel the pressed frame leaves transparent still runs ButtonCommand.
        skin.mouseMoved(x: 20, y: 1)
        t.equal(button.state, .hover)
        skin.mouseEvent(.leftDown, x: 20, y: 1)
        t.equal(button.state, .pressed)
        skin.mouseEvent(.leftUp, x: 20, y: 1)
        t.equal(skin.variable("Clicks"), "1", "press + release on the same pixel is a click")
        t.equal(button.state, .hover)

        // Pixels transparent in every frame are never part of the button.
        host.alpha = { _, x, _ in x % 40 < 3 ? 0 : 255 }
        skin.mouseMoved(x: 1, y: 10)
        t.equal(button.state, .normal)
        t.check(!skin.mouseEvent(.leftDown, x: 1, y: 10), "click on a transparent pixel falls through")
    }

    t.suite("ImageMeter review: Image meter history rules") {
        let host = FakeHost()
        host.imageSizes = ["Card.png": (120, 80), "Mask.png": (40, 40)]
        let (skin, _) = try makeSkin(t, """
        [Img]
        Meter=Image
        ImageName=Card.png
        [Masked]
        Meter=Image
        ImageName=Card.png
        MaskImageName=Mask.png
        [ZeroTint]
        Meter=Image
        ImageName=Card.png
        ImageTint=0,0,0,0
        [BlackTint]
        Meter=Image
        ImageName=Card.png
        ImageTint=0,0,0
        [BadOrigin]
        Meter=Image
        ImageName=Card.png
        ImageCrop=0,0,10,10,9
        [ZeroOrigin]
        Meter=Image
        ImageName=Card.png
        ImageCrop=0,0,10,10,0
        [CenterOrigin]
        Meter=Image
        ImageName=Card.png
        ImageCrop=0,0,10,10,5
        """, host: host)
        skin.update()
        t.equal(imageMeter(skin, "Img").frame, SkinRect(x: 0, y: 0, width: 120, height: 80))
        // "changing an image from a valid file to a non-existent file [resets] the detected size of the meter.
        // Also added an error in the log" (version history).
        skin.execute("[!SetOption Img ImageName Missing.png]", from: nil)
        skin.update()
        t.equal(imageMeter(skin, "Img").frame, SkinRect(x: 0, y: 0, width: 0, height: 0))
        t.check(host.logs.contains { $0.contains("Missing.png") }, "missing file logged")
        // "removing a MaskImageName with !SetOption" (version history).
        t.equal(imageMeter(skin, "Masked").frame.width, 40)
        skin.execute("[!SetOption Masked MaskImageName \"\"]", from: nil)
        skin.update()
        t.equal(imageMeter(skin, "Masked").maskImagePath, nil)
        t.equal(imageMeter(skin, "Masked").frame.width, 120)
        // "The alpha component of ImageTint was not being evaluated correctly if all values were zero".
        t.close(imageMeter(skin, "ZeroTint").imageOptions.drawAlpha, 0)
        t.close(imageMeter(skin, "BlackTint").imageOptions.drawAlpha, 255)
        let black = ImageOptions.apply(imageMeter(skin, "BlackTint").imageOptions.processingMatrix ?? [],
                                       r: 1, g: 0.5, b: 0.2, a: 1)
        t.equal([black.r, black.g, black.b, black.a], [0, 0, 0, 1])
        // ImageCrop Origin is one of 1…5 (default 1): an invalid origin is the default, not the nearest value.
        t.equal(imageMeter(skin, "BadOrigin").imageOptions.crop?.origin, 1)
        t.equal(imageMeter(skin, "ZeroOrigin").imageOptions.crop?.origin, 1)
        t.equal(imageMeter(skin, "CenterOrigin").imageOptions.crop?.origin, 5)
    }

    t.suite("ImageMeter review: mask pixel size guards hostile sizes") {
        t.check(ImageGeometry.pixelSize(width: 100, height: 50, scale: 2, maxPixels: 1 << 24).map { [$0.0, $0.1] }
                == [200, 100])
        t.check(ImageGeometry.pixelSize(width: 10.4, height: 10.6, scale: 1, maxPixels: 1 << 24).map { [$0.0, $0.1] }
                == [10, 11])
        t.check(ImageGeometry.pixelSize(width: 1e300, height: 20, scale: 2, maxPixels: 1 << 24) == nil)
        t.check(ImageGeometry.pixelSize(width: .infinity, height: 20, scale: 1, maxPixels: 1 << 24) == nil)
        t.check(ImageGeometry.pixelSize(width: .nan, height: 20, scale: 1, maxPixels: 1 << 24) == nil)
        t.check(ImageGeometry.pixelSize(width: 20, height: 20, scale: .nan, maxPixels: 1 << 24) == nil)
        t.check(ImageGeometry.pixelSize(width: 0.2, height: 20, scale: 1, maxPixels: 1 << 24) == nil)
        t.check(ImageGeometry.pixelSize(width: 5000, height: 5000, scale: 1, maxPixels: 1 << 24) == nil)
        t.check(ImageGeometry.pixelSize(width: 4e9, height: 4e9, scale: 1, maxPixels: .max) == nil,
                "no overflow in the pixel count")
        t.check(ImageGeometry.pixelSize(width: 1e30, height: 1, scale: 1, maxPixels: .max) == nil,
                "no Int conversion of a side beyond Int.max")
    }

    t.suite("ImageMeter review: Bitmap alignment stays on whole pixels") {
        let host = FakeHost()
        host.imageSizes = ["Digits.png": (130, 18)]
        let (skin, _) = try makeSkin(t, """
        [V]
        Measure=Calc
        Formula=7
        [Center]
        Meter=Bitmap
        MeasureName=V
        BitmapImage=Digits.png
        BitmapFrames=10
        BitmapExtend=1
        BitmapAlign=Center
        X=100
        """, host: host)
        skin.update()
        let center = skin.meter(named: "Center") as! BitmapMeter
        t.equal(center.frame.width, 13)
        t.equal(center.frame.x, center.frame.x.rounded(), "an odd width does not put the digits on half pixels")
        t.check(abs(center.frame.x + center.frame.width / 2 - 100) <= 0.5)
    }
}
