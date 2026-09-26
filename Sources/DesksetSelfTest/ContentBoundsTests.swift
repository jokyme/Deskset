import Foundation
@testable import DesksetCore

/// `Skin.contentBounds()` and `Skin.size(for:)`: what the window is sized from, and the size the engine gives it
/// (docs/editor-friendly.md §9.10). The canvas grows the widget live from these while something is dragged past its
/// edge, so they must agree with the size the engine computes after the refresh.
func runContentBoundsTests(_ t: TestRunner) {
    func loaded(_ ini: String) throws -> Skin {
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        return skin
    }

    t.suite("Editor: content bounds equal the window size for content right of and below the origin") {
        let skin = try loaded("""
            [Rainmeter]
            [Hello]
            Meter=String
            X=10
            Y=5
            Text=Hello
            [Block]
            Meter=Image
            SolidColor=255,0,0
            X=20
            Y=30
            W=100
            H=50
            [Far]
            Meter=Image
            SolidColor=0,0,255
            X=500
            Y=500
            W=10
            H=10
            Hidden=1
            """)
        // "Hello" is 5 × 7 = 35 wide and 14 high (FakeHost); the hidden block does not count.
        t.equal(skin.contentBounds(), SkinRect(x: 10, y: 5, width: 110, height: 75))
        t.equal(skin.width, 120)
        t.equal(skin.height, 80)
        t.equal(skin.size(for: skin.contentBounds()), SkinSize(width: skin.width, height: skin.height),
                "the size the engine computed")
    }

    t.suite("Editor: content bounds report content left of or above the origin") {
        let skin = try loaded("""
            [Rainmeter]
            [Panel]
            Meter=Image
            SolidColor=0,0,0,128
            W=30
            H=30
            [Title]
            Meter=Image
            SolidColor=255,255,255
            X=-12
            Y=-4
            W=50
            H=20
            """)
        let bounds = skin.contentBounds()
        t.equal(bounds, SkinRect(x: -12, y: -4, width: 50, height: 34), "negative minX and minY are kept")
        // The window still starts at the origin: the part at negative X / Y is what the desktop cuts off.
        t.equal(skin.size(for: bounds), SkinSize(width: 38, height: 30))
        t.equal(skin.size(for: bounds), SkinSize(width: skin.width, height: skin.height))

        // A live preview (a drag on the canvas) moves the bounds before anything is written.
        skin.preview(section: "Panel", ["X": "40"])
        t.equal(skin.contentBounds(), SkinRect(x: -12, y: -4, width: 82, height: 34))
        t.equal(skin.size(for: skin.contentBounds()), SkinSize(width: 70, height: 30), "grows to the right")
        skin.endPreview()
        t.equal(skin.contentBounds(), bounds)
    }

    t.suite("Editor: content bounds respect SkinWidth, SkinHeight and containers") {
        let skin = try loaded("""
            [Rainmeter]
            SkinWidth=200
            SkinHeight=100
            [Box]
            Meter=Image
            SolidColor=0,0,0
            W=60
            H=40
            [Wide]
            Meter=Image
            SolidColor=255,255,255
            X=250
            Y=10
            W=50
            H=20
            [Inside]
            Meter=Image
            SolidColor=255,0,0
            Container=Box
            X=0
            Y=0
            W=900
            H=900
            """)
        let bounds = skin.contentBounds()
        t.equal(bounds, SkinRect(x: 0, y: 0, width: 300, height: 40),
                "content of a container counts only as its container")
        t.equal(skin.size(for: bounds), SkinSize(width: 200, height: 100), "a fixed size does not grow")
        t.equal(skin.size(for: bounds), SkinSize(width: skin.width, height: skin.height))
        t.equal(skin.size(for: SkinRect(x: -40, y: -40, width: 10, height: 10)), SkinSize(width: 200, height: 100))
    }

    t.suite("Editor: content bounds include the background image, and empty content") {
        let skin = try loaded("""
            [Rainmeter]
            Background=Panel100x50.png
            [Dot]
            Meter=Image
            SolidColor=255,255,255
            X=10
            Y=60
            W=4
            H=4
            """)
        t.equal(skin.contentBounds(), SkinRect(x: 0, y: 0, width: 100, height: 64))
        t.equal(skin.size(for: skin.contentBounds()), SkinSize(width: skin.width, height: skin.height))

        let empty = try loaded("[Rainmeter]\nUpdate=1000\n")
        t.equal(empty.contentBounds(), SkinRect())
        t.equal(empty.size(for: empty.contentBounds()), SkinSize(width: empty.width, height: empty.height),
                "the smallest window")
    }
}
