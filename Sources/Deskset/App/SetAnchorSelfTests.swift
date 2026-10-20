import AppKit
import DesksetCore

/// Anchor changes use fixed desktop geometry, independent of the host's displays and backing scale.
enum SetAnchorSelfTests {
    static func run(_ t: AppTestRunner) {
        geometryTests(t)
        stateTests(t)
        validationTests(t)
        routingTests(t)
        placementTests(t)
    }

    private static func geometryTests(_ t: AppTestRunner) {
        t.suite("App: SetAnchor: pixel, percentage, edge and formula anchors keep the desktop anchor point") {
            let cases: [(oldX: String, oldY: String, newX: String, newY: String, x: CGFloat, y: CGFloat)] = [
                ("0", "0", "20", "15", 380, 315),
                ("20", "15", "50%", "50%", 320, 335),
                ("50%", "25%", "20R", "10B", 320, 365),
                ("20R", "10B", "25%R", "75%B", 430, 235),
                ("25%R", "75%B", "(10+5)R", "(30/2)B", 365, 360),
                ("(100/4)%R", "(10*5)%B", "((2+3)*4)", "(90/3)", 530, 280),
                ("0", "0", "-10", "-20", 410, 280),
                ("100%", "100%", "0R", "0B", 400, 300),
                ("0", "0", "12.5", "3.5", 387.5, 303.5)
            ]
            for value in cases {
                var model = makeModel(anchorX: value.oldX, anchorY: value.oldY)
                let changed = model.apply(Bang(name: "setanchor", args: [value.newX, value.newY]), screens: screens)
                t.check(changed != nil, "valid anchors apply: \(value.newX), \(value.newY)")
                t.equal(model.frame, CGRect(x: value.x, y: value.y, width: 200, height: 100),
                        "the actual frame moves by the old anchor minus the new anchor")
                t.equal(model.settings.anchorX, value.newX)
                t.equal(model.settings.anchorY, value.newY)
                t.equal(model.sequence, 1)
                t.equal(changed?.model.frame, model.frame)
                t.equal(changed?.sequence, model.sequence)
            }
        }

        t.suite("App: SetAnchor: absolute offsets use the displayed zoom while another zoom is pending") {
            for pendingZoom in [0.1, 1.0, 5.0] {
                var model = makeModel(frame: CGRect(x: 400, y: 300, width: 500, height: 250),
                                      anchorX: "20", anchorY: "10", zoom: 2.5)
                t.check(model.apply(Bang(name: "setzoomfactor", args: [String(pendingZoom)]), screens: screens) != nil)
                t.equal(model.settings.zoomFactor, pendingZoom)
                t.equal(model.frameZoomFactor, 2.5, "the displayed size has not followed the pending setting yet")
                t.check(model.apply(Bang(name: "setanchor", args: ["30", "15"]), screens: screens) != nil)
                t.equal(model.frame, CGRect(x: 375, y: 312.5, width: 500, height: 250))
                t.equal(model.frameZoomFactor, 2.5)
                t.equal(model.settings.zoomFactor, pendingZoom, "changing anchors does not consume the zoom request")
            }
            var percent = makeModel(frame: CGRect(x: 400, y: 300, width: 400, height: 200),
                                    anchorX: "20", anchorY: "10", zoom: 2)
            _ = percent.apply(Bang(name: "setanchor", args: ["50%", "25%"]), screens: screens)
            t.equal(percent.frame, CGRect(x: 240, y: 330, width: 400, height: 200),
                    "percentage offsets already use the displayed dimensions")
        }

        t.suite("App: SetAnchor: KeepOnScreen and selection use the existing clamp policy") {
            let origin = CGRect(x: 10, y: 780, width: 200, height: 100)
            var clamped = makeModel(frame: origin, keepOnScreen: true)
            t.check(clamped.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens) != nil)
            t.equal(clamped.frame, CGRect(x: 0, y: 770, width: 200, height: 100),
                    "the new frame stays below the menu bar and inside its display")
            t.equal(clamped.settings.anchorX, "50%")
            t.equal(clamped.settings.anchorY, "50%")

            var unconstrained = makeModel(frame: origin)
            _ = unconstrained.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens)
            t.equal(unconstrained.frame, CGRect(x: -90, y: 830, width: 200, height: 100))

            var selected = makeModel(frame: origin, keepOnScreen: true, selected: true)
            _ = selected.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens)
            t.equal(selected.frame, unconstrained.frame, "selection temporarily disables KeepOnScreen")
            t.check(selected.settings.keepOnScreen, "the saved per-skin preference stays enabled")

            var secondary = makeModel(frame: CGRect(x: -1190, y: 200, width: 200, height: 100), keepOnScreen: true)
            _ = secondary.apply(Bang(name: "setanchor", args: ["50%", "0"]), screens: screens)
            t.equal(secondary.frame, CGRect(x: -1200, y: 200, width: 200, height: 100),
                    "a secondary-display skin is clamped on that display, not moved to the primary")
        }

        t.suite("App: SetAnchor: repeated anchors and later size changes keep the same point") {
            var model = makeModel()
            _ = model.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens)
            let anchored = CGRect(x: 300, y: 350, width: 200, height: 100)
            t.equal(model.frame, anchored)
            for _ in 0..<5 {
                _ = model.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens)
                t.equal(model.frame, anchored, "repeating the same anchor does not drift")
            }
            model.resize(to: CGSize(width: 300, height: 200), screens: screens)
            t.equal(model.frame, CGRect(x: 250, y: 300, width: 300, height: 200))
            model.resize(to: CGSize(width: 150, height: 80), screens: screens)
            t.equal(model.frame, CGRect(x: 325, y: 360, width: 150, height: 80))
            t.equal(model.frame?.midX, 400)
            t.equal(model.frame?.midY, 400)
        }
    }

    private static func stateTests(_ t: AppTestRunner) {
        t.suite("App: SetAnchor: saved expressions and monitor suffixes are retained verbatim") {
            let originals: [(String?, String?)] = [
                ("(100 / 4)%R@2", "(15+5)%B@0"),
                ("(500-25)@2", "(30*2)"),
                ("50%R@2", nil),
                (nil, "20%B@0"),
                (nil, nil)
            ]
            for (x, y) in originals {
                var model = makeModel(anchorX: "10", anchorY: "20", windowX: x, windowY: y)
                _ = model.apply(Bang(name: "setanchor", args: ["50%R", "25%B"]), screens: screens)
                t.equal(model.frame, CGRect(x: 310, y: 355, width: 200, height: 100))
                t.equal(model.settings.windowX, x)
                t.equal(model.settings.windowY, y)
            }
        }

        t.suite("App: SetAnchor: SavePosition zero changes the current frame without returning to the saved point") {
            for hasExpressions in [false, true] {
                var state = SkinState(file: "Main.ini")
                state.x = 20
                state.y = 30
                state.windowX = hasExpressions ? "(20+10)@2" : nil
                state.windowY = hasExpressions ? "40" : nil
                state.anchorX = "10"
                state.anchorY = "20"
                state.savePosition = false
                state.keepOnScreen = false
                var model = makeModel(state: state, frame: CGRect(x: 700, y: 250, width: 200, height: 100))
                t.check(model.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens) != nil)
                t.equal(model.frame, CGRect(x: 610, y: 280, width: 200, height: 100),
                        "the current session frame is the reference even when its saved point differs")
                t.check(!model.settings.savePosition)
                t.equal(model.settings.windowX, state.windowX)
                t.equal(model.settings.windowY, state.windowY)
                _ = model.apply(Bang(name: "move", args: ["900", "400"]), screens: screens)
                _ = model.apply(Bang(name: "setanchor", args: ["0", "0"]), screens: screens)
                t.equal(model.frame, CGRect(x: 1000, y: 350, width: 200, height: 100),
                        "a later session-only Move becomes the current reference without replacing saved expressions")
                t.equal(model.settings.windowX, state.windowX)
                t.equal(model.settings.windowY, state.windowY)
            }
        }

        t.suite("App: SetAnchor: stale main-thread facts cannot undo a newer anchor request") {
            var model = makeModel(anchorX: "10", anchorY: "20")
            guard let initialFacts = model.facts else { return t.check(false, "initial facts exist") }
            _ = model.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens)
            let changedFrame = model.frame
            var stale = initialFacts
            stale.sequence = 2
            stale.modelSequence = 0
            stale.frame.origin.x = 20
            model.take(stale)
            t.equal(model.frame, changedFrame)
            t.equal(model.settings.anchorX, "50%")
            t.equal(model.settings.anchorY, "50%")

            var accepted = initialFacts
            accepted.sequence = 3
            accepted.modelSequence = model.sequence
            accepted.settings = model.settings
            accepted.frame = CGRect(x: 350, y: 360, width: 200, height: 100)
            model.take(accepted)
            t.equal(model.frame, accepted.frame, "acknowledged main-thread placement can still win")
            model.take(initialFacts)
            t.equal(model.frame, accepted.frame, "older publications cannot restore the original anchors")
            t.equal(model.settings.anchorX, "50%")
        }

        t.suite("App: SetAnchor: Move followed by anchor edits retains the latest saved anchor point") {
            var model = makeModel(anchorX: "20", anchorY: "10", windowX: "100", windowY: "100")
            _ = model.apply(Bang(name: "move", args: ["600", "250"]), screens: screens)
            t.equal(model.settings.windowX, "620")
            t.equal(model.settings.windowY, "260")
            _ = model.apply(Bang(name: "setanchor", args: ["40", "30"]), screens: screens)
            t.equal(model.frame, CGRect(x: 580, y: 570, width: 200, height: 100))
            t.equal(model.settings.windowX, "620")
            t.equal(model.settings.windowY, "260")
            _ = model.apply(Bang(name: "setanchor", args: ["0", "0"]), screens: screens)
            t.equal(model.frame, CGRect(x: 620, y: 540, width: 200, height: 100))
            _ = model.apply(Bang(name: "move", args: ["650", "300"]), screens: screens)
            t.equal(model.settings.windowX, "650")
            t.equal(model.settings.windowY, "300")
        }
    }

    private static func validationTests(_ t: AppTestRunner) {
        t.suite("App: SetAnchor: missing, invalid and non-finite axes leave the model unchanged atomically") {
            let arguments: [[String]] = [
                [], ["25"], ["", "10"], ["10", ""], ["garbage", "20"], ["20", "garbage"],
                ["(1+)", "20"], ["20", "(1+)"], ["nan", "20"], ["20", "nan"],
                ["inf", "20"], ["20", "-inf"], ["1e999", "20"], ["20", "1e999"],
                ["10@2", "20"], ["10", "20@1"], ["50%R@0", "20"]
            ]
            for args in arguments {
                var model = makeModel(anchorX: "10R", anchorY: "20B", windowX: "50%R@2", windowY: "20%B")
                let frame = model.frame, settings = model.settings, facts = model.facts
                let sequence = model.sequence
                let result = model.apply(Bang(name: "setanchor", args: args), screens: screens)
                t.check(result == nil, "invalid anchors are rejected: \(args)")
                t.equal(model.sequence, sequence)
                t.equal(model.frame, frame)
                t.equal(model.settings, settings, "one valid axis cannot partially change the other axis")
                t.equal(model.facts, facts)
            }
        }
    }

    private static func routingTests(_ t: AppTestRunner) {
        t.suite("App: SetAnchor: target routing keeps both anchors and trims only target metadata") {
            let cases: [([String], SkinWindowBangs.Targets)] = [
                (["(10+5)R", "50%"], .own),
                (["(10+5)R", "50%", ""], .own),
                (["(10+5)R", "50%", "Suite/Card"], .config("Suite\\Card")),
                (["(10+5)R", "50%", "*"], .config("*")),
                (["(10+5)R", "50%", "Group=alpha|beta"], .group("alpha|beta")),
                (["(10+5)R", "50%", "Group=alpha&beta"], .group("alpha&beta"))
            ]
            for (args, expected) in cases {
                let bang = Bang(name: "setanchor", args: args, literalArguments: args.count == 2 ? [0, 1] : [0, 1, 2])
                guard let routed = SkinWindowBangs.targets(of: bang) else {
                    t.check(false, "SetAnchor is recognized as a window bang")
                    continue
                }
                t.equal(routed.targets, expected)
                t.equal(routed.member.name, "setanchor")
                t.equal(routed.member.args, ["(10+5)R", "50%"])
                t.equal(routed.member.literalArguments, Set([0, 1]), "target argument at index 2 is removed with its literal marker")
            }
            t.check(SkinWindowBangs.targets(of: Bang(name: "setanchorgroup", args: ["0", "0", "alpha"])) == nil,
                    "no undocumented SetAnchorGroup form is introduced")
        }
    }

    private static func placementTests(_ t: AppTestRunner) {
        t.suite("App: SetAnchor: initial placement preserves session, expression and legacy precedence") {
            var state = SkinState(file: "Main.ini")
            state.x = 400
            state.y = 500
            state.windowX = "600"
            state.windowY = "300"
            state.anchorX = "20"
            state.anchorY = "10"
            state.keepOnScreen = false
            var context = placementContext(state, session: NSPoint(x: 100, y: 200))
            let size = CGSize(width: 200, height: 100)
            var settings = SkinWindowSettings(state, hidden: false, fadedAlpha: nil)
            let raw = context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1)
            t.equal(raw.frame, CGRect(x: 580, y: 510, width: 200, height: 100))
            t.equal(raw.resolvedLayoutPosition, NSPoint(x: 580, y: 290))
            t.check(!raw.isNew)

            settings.savePosition = false
            let session = context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1)
            t.equal(session.frame, CGRect(x: 100, y: 600, width: 200, height: 100),
                    "a SavePosition=0 session move takes precedence over saved expressions")
            t.equal(session.resolvedLayoutPosition, nil)
            t.check(!session.isNew)
            context.sessionPosition = nil
            t.equal(context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1).frame, raw.frame,
                    "without a session move the saved expressions still apply")

            settings.windowX = nil
            settings.windowY = nil
            settings.savePosition = true
            context.sessionPosition = NSPoint(x: 100, y: 200)
            t.equal(context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1).frame,
                    CGRect(x: 400, y: 300, width: 200, height: 100), "legacy x/y remain top-left coordinates")
            settings.savePosition = false
            t.equal(context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1).frame, session.frame)
        }

        t.suite("App: SetAnchor: initial placement keeps a missing expression axis at zero") {
            for xMissing in [false, true] {
                var state = SkinState(file: "Main.ini")
                state.x = 700
                state.y = 300
                state.windowX = xMissing ? nil : "600"
                state.windowY = xMissing ? "300" : nil
                state.anchorX = "20"
                state.anchorY = "10"
                state.keepOnScreen = false
                let context = placementContext(state)
                let settings = SkinWindowSettings(state, hidden: false, fadedAlpha: nil, isSelected: true)
                let result = context.resolve(settings: settings, size: CGSize(width: 200, height: 100),
                                             screens: screens, zoomFactor: 1)
                let point = xMissing ? NSPoint(x: -20, y: 290) : NSPoint(x: 580, y: -10)
                t.equal(result.resolvedLayoutPosition, point, "the missing axis does not borrow legacy saved x/y")
                t.equal(result.frame, xMissing ? CGRect(x: -20, y: 510, width: 200, height: 100)
                                               : CGRect(x: 580, y: 810, width: 200, height: 100))
                t.check(!result.isNew)
            }
        }

        t.suite("App: SetAnchor: first cascade materializes its original anchor point before an anchor edit") {
            var state = SkinState(file: "Main.ini")
            state.anchorX = "20"
            state.anchorY = "10"
            state.keepOnScreen = false
            state.savePosition = false
            var context = placementContext(state)
            let size = CGSize(width: 200, height: 100)
            let settings = SkinWindowSettings(state, hidden: false, fadedAlpha: nil)
            let cascade = context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1)
            t.equal(cascade.frame, CGRect(x: 120, y: 650, width: 200, height: 100))
            t.check(cascade.isNew)
            t.equal(cascade.resolvedLayoutPosition, nil)
            var model = SkinWindowModel()
            model.settings = settings
            model.seedPlacement(cascade, zoomFactor: 1, screens: screens)
            t.check(model.forceSaveInitialPosition, "a new position is stored once even with SavePosition=0")
            t.equal(model.settings.windowX, "140")
            t.equal(model.settings.windowY, "160")
            _ = model.apply(Bang(name: "setanchor", args: ["50%", "50%"]), screens: screens)
            t.equal(model.frame, CGRect(x: 40, y: 690, width: 200, height: 100))
            t.equal(model.settings.windowX, "140")
            t.equal(model.settings.windowY, "160")

            context.defaultPosition = ("500", "400", "50%", "50%")
            let defaultPlacement = context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1)
            t.equal(defaultPlacement.frame, CGRect(x: 400, y: 450, width: 200, height: 100))
            t.check(defaultPlacement.isNew, "configured defaults precede cascading when there is no saved position")

            state.x = 700
            state.y = 300
            let saved = placementContext(state).resolve(settings: settings, size: size, screens: screens, zoomFactor: 1)
            t.equal(saved.frame, CGRect(x: 700, y: 500, width: 200, height: 100))
            t.check(!saved.isNew)
            model = SkinWindowModel()
            model.settings = settings
            model.seedPlacement(saved, zoomFactor: 1, screens: screens)
            t.check(!model.forceSaveInitialPosition)
            t.equal(model.settings.windowX, nil, "existing legacy coordinates are left for the controller's persistence policy")
            t.equal(model.settings.windowY, nil)
        }

        t.suite("App: SetAnchor: initial placement retains selection and offscreen rescue behavior") {
            var state = SkinState(file: "Main.ini")
            state.x = -5000
            state.y = -5000
            state.keepOnScreen = false
            let context = placementContext(state)
            var settings = SkinWindowSettings(state, hidden: false, fadedAlpha: nil)
            let size = CGSize(width: 200, height: 100)
            t.equal(context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1).frame,
                    CGRect(x: -1200, y: 800, width: 200, height: 100), "an entirely offscreen legacy position is rescued")
            settings.isSelected = true
            t.equal(context.resolve(settings: settings, size: size, screens: screens, zoomFactor: 1).frame,
                    CGRect(x: -5000, y: 5800, width: 200, height: 100), "selection retains the temporary offscreen position")

            state.x = 10
            state.y = 20
            state.keepOnScreen = true
            let clamped = placementContext(state).resolve(settings: SkinWindowSettings(state, hidden: false, fadedAlpha: nil),
                size: size, screens: screens, zoomFactor: 1)
            t.equal(clamped.frame, CGRect(x: 10, y: 770, width: 200, height: 100), "initial clamp uses the same menu-bar boundary")
        }
    }

    private static func placementContext(_ state: SkinState, session: NSPoint? = nil) -> SkinPlacementContext {
        SkinPlacementContext(state: state, sessionPosition: session, cascadeIndex: 2,
                             cascadeVisibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 870))
    }

    private static func makeModel(frame: CGRect = CGRect(x: 400, y: 300, width: 200, height: 100),
                                  anchorX: String = "0", anchorY: String = "0",
                                  windowX: String? = nil, windowY: String? = nil, zoom: Double = 1,
                                  keepOnScreen: Bool = false, selected: Bool = false) -> SkinWindowModel {
        var state = SkinState(file: "Main.ini")
        state.anchorX = anchorX
        state.anchorY = anchorY
        state.windowX = windowX
        state.windowY = windowY
        state.zoomFactor = zoom
        state.keepOnScreen = keepOnScreen
        return makeModel(state: state, frame: frame, zoom: zoom, selected: selected)
    }

    private static func makeModel(state: SkinState, frame: CGRect, zoom: Double = 1,
                                  selected: Bool = false) -> SkinWindowModel {
        var model = SkinWindowModel()
        var facts = SkinWindowFacts(frame: frame, isVisible: true, isOrderedIn: true, scale: 1,
                                    takesPointer: true,
                                    settings: SkinWindowSettings(state, hidden: false, fadedAlpha: nil, isSelected: selected),
                                    frameZoomFactor: zoom, sequence: 1)
        facts.hasPlacedWindow = true
        model.take(facts)
        return model
    }

    private static let screens = [
        WindowGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 870)),
        WindowGeometry.Screen(frame: CGRect(x: -1200, y: 0, width: 1200, height: 900),
                              visibleFrame: CGRect(x: -1200, y: 0, width: 1200, height: 900))
    ]
}
