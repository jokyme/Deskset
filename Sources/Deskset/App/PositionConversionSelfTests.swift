import AppKit
import DesksetCore

/// Position mode changes reuse the existing coordinate resolver with deterministic monitor geometry.
enum PositionConversionSelfTests {
    static func run(_ t: AppTestRunner) {
        serializationTests(t)
        modeTests(t)
        anchorTests(t)
        monitorTests(t)
        fallbackTests(t)
    }

    private static func serializationTests(_ t: AppTestRunner) {
        t.suite("App: Position conversion: finite coordinate templates retain every modifier") {
            let values: [(String, Character, String)] = [
                ("(100 / 4)%R@2", "R", "25%R@2"),
                ("-12.375B@0", "B", "-12.375B@0"),
                ("50%", "R", "50%"),
                ("10@2", "B", "10@2"),
                ("-0", "R", "0")
            ]
            for (raw, end, expected) in values {
                guard let coordinate = WindowPosition.parse(raw, endLetter: end) else {
                    t.check(false, "the coordinate parses: \(raw)")
                    continue
                }
                t.equal(coordinate.expression(endLetter: end), expected)
                t.equal(WindowPosition.parse(coordinate.expression(endLetter: end), endLetter: end), coordinate)
            }
            for raw in ["nan", "inf", "-inf", "1e999", "1e999%R@2"] {
                t.equal(WindowPosition.parse(raw, endLetter: "R"), nil, "non-finite coordinate input is rejected")
            }
            for value in [Double.nan, .infinity, -.infinity] {
                let coordinate = WindowPosition.Coordinate(value: value, percent: true, fromEnd: true, screen: 2)
                t.equal(coordinate.expression(endLetter: "R"), "0%R@2", "a template never writes a non-finite value")
            }
        }
    }

    private static func modeTests(_ t: AppTestRunner) {
        t.suite("App: Position conversion: percentage and right-bottom modes keep the current top-left") {
            let screens = [AppSelfTest.screen, AppSelfTest.screen2]
            let size = CGSize(width: 237, height: 113)
            guard let point = WindowPosition.resolve(x: "(100 / 4)%R@2", y: "30%B", anchorX: "0", anchorY: "0",
                                                       skinSize: size, screens: screens) else {
                return t.check(false, "the original relative coordinates resolve")
            }
            for percentX in [false, true] {
                for percentY in [false, true] {
                    for fromRight in [false, true] {
                        for fromBottom in [false, true] {
                            var x = WindowPosition.parse("(100 / 4)%R@2", endLetter: "R")!
                            var y = WindowPosition.parse("30%B", endLetter: "B")!
                            x.percent = percentX
                            y.percent = percentY
                            x.fromEnd = fromRight
                            y.fromEnd = fromBottom
                            let result = converted(t, point: point, x: x, y: y, anchorX: "0", anchorY: "0",
                                                   size: size, screens: screens)
                            t.equal(WindowPosition.parse(result.x, endLetter: "R")?.percent, percentX)
                            t.equal(WindowPosition.parse(result.y, endLetter: "B")?.percent, percentY)
                            t.equal(WindowPosition.parse(result.x, endLetter: "R")?.fromEnd, fromRight)
                            t.equal(WindowPosition.parse(result.y, endLetter: "B")?.fromEnd, fromBottom)
                            t.equal(WindowPosition.parse(result.x, endLetter: "R")?.screen, 2)
                            t.equal(WindowPosition.parse(result.y, endLetter: "B")?.screen, nil,
                                    "a monitor inherited from X does not add a suffix to Y")
                        }
                    }
                }
            }
        }
    }

    private static func anchorTests(_ t: AppTestRunner) {
        t.suite("App: Position conversion: anchors and zoom preserve negative positions on unequal displays") {
            let screens = unevenScreens
            let point = (x: -973.25, y: -658.5)
            let anchors = [("0", "0"), ("50%", "50%"), ("15", "20"), ("15R", "20B"), ("25%R", "75%B")]
            for zoom in [0.1, 1, 2.5, 5] {
                for (anchorX, anchorY) in anchors {
                    for percent in [false, true] {
                        for fromEnd in [false, true] {
                            let x = WindowPosition.Coordinate(value: 0, percent: percent, fromEnd: fromEnd, screen: 0)
                            let y = WindowPosition.Coordinate(value: 0, percent: !percent, fromEnd: !fromEnd)
                            converted(t, point: point, x: x, y: y, anchorX: anchorX, anchorY: anchorY,
                                      size: CGSize(width: 237 * zoom, height: 113 * zoom), screens: screens, zoom: zoom)
                        }
                    }
                }
            }
        }
    }

    private static func monitorTests(_ t: AppTestRunner) {
        t.suite("App: Position conversion: default, virtual, numbered and inherited monitor modes") {
            let point = (x: -1250.75, y: 319.125)
            let screens = unevenScreens
            let screenOptions: [Int?] = [nil, 0, 1, 2]
            for screen in screenOptions {
                let x = WindowPosition.Coordinate(value: 50, percent: true, fromEnd: true, screen: screen)
                let y = WindowPosition.Coordinate(value: 25, percent: true, fromEnd: true, screen: screen)
                let result = converted(t, point: point, x: x, y: y, anchorX: "20", anchorY: "10B",
                                       size: CGSize(width: 210, height: 130), screens: screens, zoom: 1.5)
                t.equal(WindowPosition.parse(result.x, endLetter: "R")?.screen, screen)
                t.equal(WindowPosition.parse(result.y, endLetter: "B")?.screen, screen)
            }
            for suffixOnX in [false, true] {
                let x = WindowPosition.Coordinate(value: 0, percent: true, screen: suffixOnX ? 2 : nil)
                let y = WindowPosition.Coordinate(value: 0, fromEnd: true, screen: suffixOnX ? nil : 2)
                let result = converted(t, point: point, x: x, y: y, anchorX: "50%", anchorY: "0B",
                                       size: CGSize(width: 210, height: 130), screens: screens)
                t.equal(WindowPosition.parse(result.x, endLetter: "R")?.screen, suffixOnX ? 2 : nil)
                t.equal(WindowPosition.parse(result.y, endLetter: "B")?.screen, suffixOnX ? nil : 2)
            }
            let autoPoint = (x: -1100.0, y: 300.0)
            let auto = converted(t, point: autoPoint,
                x: .init(value: 0, percent: true, fromEnd: true, screen: 0),
                y: .init(value: 0, percent: true, fromEnd: true, screen: 0),
                anchorX: "50%", anchorY: "50%", size: CGSize(width: 200, height: 100), screens: screens,
                autoSelectScreen: true)
            t.equal(WindowPosition.parse(auto.x, endLetter: "R")?.screen, 2,
                    "auto-selection uses the display containing the current frame")
            t.equal(WindowPosition.parse(auto.y, endLetter: "B")?.screen, 2)
        }
    }

    private static func fallbackTests(_ t: AppTestRunner) {
        t.suite("App: Position conversion: zero skin size and unavailable displays keep finite fallback coordinates") {
            for screens in [[], unevenScreens] {
                converted(t, point: (120.25, -40.5),
                    x: .init(value: 0, percent: true, fromEnd: true, screen: 2),
                    y: .init(value: 0, percent: true, fromEnd: true),
                    anchorX: "50%R", anchorY: "50%B", size: .zero, screens: screens, autoSelectScreen: true)
            }
            let noDisplay = WindowPosition.moved(x: 192, y: 108, windowX: "0%", windowY: "0%",
                anchorX: nil, anchorY: nil, skinSize: .zero, screens: [], autoSelectScreen: true)
            t.equal(noDisplay.x, "10%", "no display uses the existing 1920 by 1080 desktop fallback")
            t.equal(noDisplay.y, "10%")
            let zeroDisplay = [WindowGeometry.Screen(frame: .zero, visibleFrame: .zero)]
            converted(t, point: (40, -20), x: .init(value: 0), y: .init(value: 0, fromEnd: true),
                      anchorX: "15R", anchorY: "20B", size: .zero, screens: zeroDisplay)
            let zeroPercent = WindowPosition.moved(x: 0, y: 0, windowX: "0%R", windowY: "0%B",
                anchorX: nil, anchorY: nil, skinSize: .zero, screens: zeroDisplay, autoSelectScreen: false)
            t.equal(zeroPercent.x, "0%R")
            t.equal(zeroPercent.y, "0%B")
            t.check(WindowPosition.parse(zeroPercent.x, endLetter: "R")?.value.isFinite == true)
            t.check(WindowPosition.parse(zeroPercent.y, endLetter: "B")?.value.isFinite == true)
        }
    }

    @discardableResult
    private static func converted(_ t: AppTestRunner, point: (x: Double, y: Double),
                                  x: WindowPosition.Coordinate, y: WindowPosition.Coordinate,
                                  anchorX: String, anchorY: String, size: CGSize,
                                  screens: [WindowGeometry.Screen], zoom: Double = 1,
                                  autoSelectScreen: Bool = false) -> (x: String, y: String) {
        let result = WindowPosition.moved(x: point.x, y: point.y,
            windowX: x.expression(endLetter: "R"), windowY: y.expression(endLetter: "B"),
            anchorX: anchorX, anchorY: anchorY, skinSize: size, screens: screens,
            autoSelectScreen: autoSelectScreen, zoomFactor: zoom)
        t.check(WindowPosition.parse(result.x, endLetter: "R")?.value.isFinite == true)
        t.check(WindowPosition.parse(result.y, endLetter: "B")?.value.isFinite == true)
        guard let restored = WindowPosition.resolve(x: result.x, y: result.y, anchorX: anchorX, anchorY: anchorY,
                                                    skinSize: size, screens: screens, zoomFactor: zoom) else {
            t.check(false, "converted coordinates resolve")
            return result
        }
        t.close(restored.x, point.x, "changing the mode preserves the frame's left edge")
        t.close(restored.y, point.y, "changing the mode preserves the frame's top edge")
        return result
    }

    private static let unevenScreens = [
        WindowGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        WindowGeometry.Screen(frame: CGRect(x: -1280, y: -200, width: 1280, height: 1024),
                              visibleFrame: CGRect(x: -1280, y: -200, width: 1280, height: 1024)),
        WindowGeometry.Screen(frame: CGRect(x: 180, y: 900, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 180, y: 900, width: 1920, height: 1080))
    ]
}
