import AppKit
import DesksetCore

/// `--render --clock` runs the skin in virtual time (a `VirtualTimeExecutor`): updates are virtual ticks, `!Delay` and
/// timers run at their own virtual times, local files are fixtures, and a render waits for nothing in real time.
enum VirtualTimeRenderSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: render: --clock runs in virtual time, the same on every run, without real waits") {
            let skins = t.temporaryDirectory("virtual-render").appendingPathComponent("Skins")
            let dir = skins.appendingPathComponent("Virtual/Render")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Half a minute after the refresh, the square turns red: that is between the first and the second
            // update, a minute apart.
            try """
            [Rainmeter]
            Update=1000
            DynamicWindowSize=1
            BackgroundMode=2
            SolidColor=20,20,20,255
            OnRefreshAction=[!Delay 30000][!SetOption Late SolidColor 255,0,0,255][!UpdateMeter Late][!Redraw]
            [Quote]
            Measure=Plugin
            Plugin=QuotePlugin
            PathName=#CURRENTPATH#quotes.txt
            [Late]
            Meter=Image
            W=20
            H=20
            SolidColor=0,0,255,255
            [Text]
            Meter=String
            MeasureName=Quote
            Text=%1
            Y=24
            FontSize=10
            FontColor=255,255,255,255
            AntiAlias=1
            """.write(to: dir.appendingPathComponent("Render.ini"), atomically: true, encoding: .utf8)
            try "north\nsouth\neast\nwest\nup\ndown".write(to: dir.appendingPathComponent("quotes.txt"), atomically: true,
                                                            encoding: .utf8)
            let out = t.temporaryDirectory("virtual-render-out")
            func render(_ name: String, _ extra: [String] = []) -> (status: Int32, seconds: TimeInterval, png: Data?) {
                let png = out.appendingPathComponent(name)
                let started = ProcessInfo.processInfo.systemUptime
                // Three updates a minute apart: two minutes of waiting in real time, none in virtual time.
                let status = RenderCommand.run(["Deskset", "--render", dir.appendingPathComponent("Render.ini").path,
                                                "--out", png.path, "--updates", "3", "--interval", "60000",
                                                "--scale", "1", "--clock", "2026-09-28T09:00:00Z", "--seed", "7"]
                                               + extra)
                return (status, ProcessInfo.processInfo.systemUptime - started, try? Data(contentsOf: png))
            }
            let first = render("first.png"), second = render("second.png")
            t.equal(first.status, 0)
            t.equal(second.status, 0)
            // Only tells "virtual" from "waited two real minutes".
            t.check(first.seconds < 30 && second.seconds < 30, "no real waits: \(first.seconds) s, \(second.seconds) s")
            t.check(first.png != nil && first.png == second.png, "byte for byte the same image on every run")
            guard let data = first.png, let rep = NSBitmapImageRep(data: data),
                  let square = rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB) else {
                t.check(false, "the render is readable")
                return
            }
            t.check(square.redComponent > 0.9 && square.blueComponent < 0.1,
                    "the delayed action ran at its virtual time: \(square)")
            t.check(rep.pixelsHigh > 30, "the quote, a fixture read in virtual time, is shown: \(rep.pixelsHigh) px high")

            // --color-space srgb: the same picture in an sRGB bitmap, also the same on every run.
            let srgb = render("srgb.png", ["--color-space", "srgb"]), srgb2 = render("srgb2.png", ["--color-space", "srgb"])
            t.equal(srgb.status, 0)
            t.check(srgb.png != nil && srgb.png == srgb2.png, "an sRGB render is the same on every run")
            guard let sData = srgb.png, let sRep = NSBitmapImageRep(data: sData) else {
                t.check(false, "the sRGB render is readable")
                return
            }
            t.equal(sRep.colorSpace.colorSpaceModel, .rgb)
            t.equal(sRep.colorSpace.cgColorSpace?.name, CGColorSpace.sRGB, "the sRGB render is in sRGB")
            t.equal(sRep.pixelsWide, rep.pixelsWide)
            t.equal(sRep.pixelsHigh, rep.pixelsHigh)
            let sSquare = sRep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB)
            t.check((sSquare?.redComponent ?? 0) > 0.9 && (sSquare?.blueComponent ?? 1) < 0.1,
                    "the same picture: \(String(describing: sSquare))")
        }
    }
}
