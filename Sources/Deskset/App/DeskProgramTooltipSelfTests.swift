import AppKit
import DesksetCore

enum DeskProgramTooltipSelfTests {
    private typealias S = DeskConditionalTestSupport
    private typealias P = DeskProgramTooltips
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private final class Model {
        var pointer = NSPoint.zero
        var target: P.Target?
        var lastPoint: NSPoint?
        var screens = [WindowGeometry.Screen(frame: CGRect(x: -400, y: -300, width: 400, height: 300),
            visibleFrame: CGRect(x: -400, y: -300, width: 400, height: 280))]
    }
    private struct Fixture {
        let time: VirtualTimeExecutor
        let window: NSWindow
        let view: NSView
        let model: Model
        let defaults: UserDefaults
        let presenter: P
        func point(_ local: NSPoint) { model.pointer = window.convertPoint(toScreen: view.convert(local, to: nil)) }
        func move(_ local: NSPoint = NSPoint(x: 90, y: 60)) { point(local); presenter.mouseMoved(at: local) }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk tooltips: complete hit map selects empty children independently of actions and INI area limits") {
            let revision = P.Revision(session: UUID(), epoch: 4, generation: 8)
            let box = SkinRect(width: 100, height: 80), child = SkinRect(x: 20, y: 20, width: 20, height: 20)
            var map = SkinHitMap()
            map.entries = [entry("empty", 2, child, ToolTipInfo(text: "")),
                           entry("parent", 1, box, ToolTipInfo(text: "parent", title: "Title"))]
            t.equal(P.target(in: map, at: SkinPoint(x: 25, y: 25), revision: revision)?.id.name, "empty")
            t.equal(P.target(in: map, at: SkinPoint(x: 25, y: 25), revision: revision)?.info, ToolTipInfo(text: ""))
            t.check(map.entry(at: 25, 25, handling: .leftUp, images: nil) == nil, "tooltip-only entries never catch clicks")
            t.equal(P.target(in: map, at: SkinPoint(x: 1, y: 1), revision: revision)?.id.name, "parent")
            map.entries[0] = entry("child", 2, child, nil)
            t.equal(P.target(in: map, at: SkinPoint(x: 25, y: 25), revision: revision)?.id.name, "parent")
            map.entries = (0..<600).map { entry("outside", $0, SkinRect(x: 200, y: 200, width: 10, height: 10), ToolTipInfo(text: "outside")) }
            map.entries.append(entry("last", 601, box, ToolTipInfo(text: "last")))
            t.equal(map.toolTipAreas, [])
            t.equal(P.target(in: map, at: SkinPoint(x: 50, y: 40), revision: revision)?.id.index, 601)
            t.check(P.target(in: map, at: SkinPoint(x: 100, y: 40), revision: revision) == nil)
            t.check(P.target(in: map, at: SkinPoint(x: .nan, y: 40), revision: revision) == nil)
            map.toolTipHidden = true
            t.check(P.target(in: map, at: SkinPoint(x: 50, y: 40), revision: revision) == nil)
        }

        t.suite("App: Desk tooltips: native attributed title body delay and screen clamp preserve an inactive pointer-transparent panel") {
            let f = try fixture(t, text: "Battery is charging.\n电量 73% 🔋", title: "Power status")
            f.defaults.set(200, forKey: "NSInitialToolTipDelay")
            t.close(f.presenter.initialDelay, 0.2)
            f.move(NSPoint(x: 178, y: 110))
            t.check(f.presenter.pending); f.time.advance(by: 0.199); t.check(f.presenter.shownTarget == nil)
            f.time.advance(by: 0.001)
            t.equal(f.presenter.shownTarget, f.model.target); t.check(!f.presenter.pending)
            guard let panel = f.presenter.panel, let content = panel.contentView,
                  let label = content.subviews.first as? NSTextField, let words = f.presenter.attributedText else { throw S.Failure.fixture }
            t.equal(words.string, "Power status\nBattery is charging.\n电量 73% 🔋")
            guard let titleFont = words.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                  let bodyFont = words.attribute(.font, at: "Power status\n".utf16.count, effectiveRange: nil) as? NSFont else { throw S.Failure.fixture }
            t.check(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
            t.check(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
            t.equal(titleFont.pointSize, bodyFont.pointSize)
            t.check(panel.styleMask.contains(.nonactivatingPanel) && !panel.styleMask.contains(.titled))
            t.check(!panel.canBecomeKey && !panel.canBecomeMain && panel.ignoresMouseEvents)
            t.check(!panel.isVisible && panel.parent == nil && f.window.childWindows?.isEmpty != false)
            t.check(f.model.screens[0].visibleFrame.insetBy(dx: 4, dy: 4).contains(panel.frame))
            let plain = NSTextField(wrappingLabelWithString: words.string)
            plain.font = .systemFont(ofSize: NSFont.smallSystemFontSize); plain.textColor = .labelColor
            plain.maximumNumberOfLines = 0; plain.preferredMaxLayoutWidth = label.preferredMaxLayoutWidth
            plain.frame = label.bounds; plain.appearance = label.effectiveAppearance
            for scale in [1, 2] {
                let actual = try S.bytes(S.paint(label, scale: scale))
                t.check(actual.contains(where: { $0 != 0 }), "native text produces pixels at \(scale)x")
                t.check(actual != (try S.bytes(S.paint(plain, scale: scale))), "plain title is a negative native pixel control")
            }
            f.defaults.set(-1, forKey: "NSInitialToolTipDelay")
            t.close(f.presenter.initialDelay, Double(SkinTooltips.initialDelayMilliseconds) / 1000)
        }

        t.suite("App: Desk tooltips: accepted refresh preserves dwell but an unrefreshed revision or another window invalidates delayed work") {
            let f = try fixture(t)
            f.move(); f.time.advance(by: 0.25)
            guard let original = f.model.target else { throw S.Failure.fixture }
            let next = P.Target(id: original.id, info: ToolTipInfo(text: "new accepted text", title: "New title"),
                revision: P.Revision(session: original.revision.session, epoch: original.revision.epoch, generation: 2))
            f.model.target = next; f.presenter.refresh(); f.time.advance(by: 0.25)
            t.equal(f.presenter.shownTarget, next, "ordinary frame updates do not restart the hover delay")
            f.presenter.cancel(); f.move()
            f.model.target = P.Target(id: original.id, info: original.info,
                revision: P.Revision(session: original.revision.session, epoch: original.revision.epoch, generation: 3))
            f.time.advance(by: 0.5)
            t.check(f.presenter.shownTarget == nil && f.presenter.selectedTarget == nil,
                    "a delayed ticket cannot adopt an adapter revision it never accepted through refresh")
            f.move()
            let other = NSWindow(contentRect: f.window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            t.atSuiteEnd { other.close() }
            other.contentView = f.view
            f.time.advance(by: 0.5)
            t.check(f.presenter.selectedTarget == nil && f.presenter.shownTarget == nil, "a reused NSView cannot publish its old window's tooltip")
            t.equal(f.time.background.reports, [])
        }

        t.suite("App: Desk tooltips: presses exits empty targets and parent lifecycle cancel without reopening on refresh") {
            let f = try fixture(t)
            guard let original = f.model.target else { throw S.Failure.fixture }
            f.move(); f.time.advance(by: 0.5); t.check(f.presenter.shownTarget != nil)
            f.presenter.mouseDown(); f.presenter.refresh(); f.time.advance(by: 2)
            t.check(f.presenter.shownTarget == nil && !f.presenter.pending)
            f.presenter.cancel(); f.presenter.refresh(); t.check(!f.presenter.pending, "cancel cannot undo press suppression")
            f.move(); f.time.advance(by: 0.5); t.check(f.presenter.shownTarget != nil)
            f.presenter.mouseExited(); f.presenter.refresh(); f.time.advance(by: 1)
            t.check(f.presenter.shownTarget == nil && !f.presenter.pending)
            f.model.target = P.Target(id: original.id, info: ToolTipInfo(text: "", title: "Title only"), revision: original.revision)
            f.move(); f.time.advance(by: 0.5); t.equal(f.presenter.attributedText?.string, "Title only")
            f.model.target = P.Target(id: original.id, info: ToolTipInfo(text: ""), revision: original.revision)
            f.presenter.refresh()
            t.equal(f.presenter.selectedTarget, f.model.target)
            t.check(f.presenter.shownTarget == nil && !f.presenter.pending && f.presenter.attributedText == nil)
            f.model.target = original
            for notification in [NSWindow.willMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                for shown in [false, true] {
                    f.move()
                    if shown { f.time.advance(by: 0.5); t.check(f.presenter.shownTarget != nil) }
                    NotificationCenter.default.post(name: notification, object: f.window)
                    t.check(f.presenter.selectedTarget == nil && f.presenter.shownTarget == nil && !f.presenter.pending)
                    f.presenter.refresh(); f.time.advance(by: 1)
                    t.check(f.presenter.shownTarget == nil && !f.presenter.pending)
                }
            }
            f.move(); f.presenter.close(); f.time.advance(by: 1); f.move(); f.presenter.refresh()
            t.check(f.presenter.isClosed && f.presenter.selectedTarget == nil && f.presenter.panel == nil && !f.presenter.pending)
        }

        t.suite("App: Desk tooltips: native view coordinates handle negative bounds zoom and visibility without ordering test windows") {
            let f = try fixture(t)
            f.view.bounds = NSRect(x: -40, y: -20, width: 90, height: 60)
            let local = NSPoint(x: -10, y: 5)
            f.move(local); f.presenter.refresh()
            t.close(f.model.lastPoint?.x ?? .nan, local.x); t.close(f.model.lastPoint?.y ?? .nan, local.y)
            f.time.advance(by: 0.5); t.check(f.presenter.shownTarget != nil)
            f.presenter.cancel(); f.move(local)
            f.point(NSPoint(x: 90, y: 80)); f.time.advance(by: 0.5)
            t.check(f.presenter.shownTarget == nil && !f.presenter.pending, "timer rechecks the pointer against the visible view")
            f.move(local); f.view.isHidden = true; f.time.advance(by: 0.5)
            t.check(f.presenter.shownTarget == nil && !f.presenter.pending)
            f.view.isHidden = false
            let strict = P(view: f.view, executor: f.time, defaults: f.defaults,
                pointerLocation: { f.model.pointer }, screens: { f.model.screens }, presentsWindows: true,
                targetAt: { _ in f.model.target })
            defer { strict.close() }
            strict.mouseMoved(at: local); f.time.advance(by: 1)
            t.check(strict.selectedTarget == nil && strict.panel == nil && !strict.pending,
                    "a real presenter refuses an ordered-out parent; only the explicit fixture mode bypasses that gate")
            t.check(!f.window.isVisible)
        }

        t.suite("App: Desk tooltips: a cancelled callback delivered late cannot hide or reveal a replacement target") {
            let f = try fixture(t), executor = LateExecutor()
            let p = P(view: f.view, executor: executor, defaults: f.defaults,
                pointerLocation: { f.model.pointer }, screens: { f.model.screens }, presentsWindows: false,
                targetAt: { _ in f.model.target })
            defer { p.close() }
            let point = NSPoint(x: 90, y: 60); f.point(point)
            p.mouseMoved(at: point)
            guard executor.work.count == 1, let old = f.model.target else { throw S.Failure.fixture }
            p.cancel()
            f.model.target = P.Target(id: ElementID(name: "replacement", index: 1), info: ToolTipInfo(text: "replacement"), revision: old.revision)
            p.mouseMoved(at: point)
            t.equal(executor.work.count, 2)
            executor.work[0]()
            t.equal(p.selectedTarget, f.model.target); t.check(p.pending && p.shownTarget == nil)
            executor.work[1]()
            t.equal(p.shownTarget, f.model.target); t.check(!p.pending)
            p.cancel(); executor.work[1]()
            t.check(p.selectedTarget == nil && p.shownTarget == nil && !p.pending)
        }
    }

    private static func entry(_ name: String, _ index: Int, _ frame: SkinRect, _ tip: ToolTipInfo?) -> SkinHitMap.Entry {
        SkinHitMap.Entry(name: name, frame: frame, shape: .rect(frame), container: nil, glass: nil, isButton: false,
            actions: [:], cursor: true, cursorName: "", toolTip: tip, elementID: ElementID(name: name, index: index))
    }

    private static func fixture(_ t: AppTestRunner, text: String = "Body", title: String = "Title") throws -> Fixture {
        let time = try S.clock(), model = Model(), name = "app.deskset.selftest.tooltips.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw S.Failure.fixture }
        defaults.set(500, forKey: "NSInitialToolTipDelay")
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let window = NSWindow(contentRect: NSRect(x: -180, y: -120, width: 180, height: 120),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        model.target = P.Target(id: ElementID(name: "card", index: 0), info: ToolTipInfo(text: text, title: title),
            revision: P.Revision(session: UUID(), epoch: 1, generation: 1))
        let presenter = P(view: view, executor: time, defaults: defaults,
            pointerLocation: { model.pointer }, screens: { model.screens }, presentsWindows: false) { point in
                model.lastPoint = point
                return model.target
            }
        t.atSuiteEnd { presenter.close(); window.close(); time.runUntilIdle(); defaults.removePersistentDomain(forName: name) }
        return Fixture(time: time, window: window, view: view, model: model, defaults: defaults, presenter: presenter)
    }

    /// Deliberately delivers the raw callback even after cancellation, representing work already handed to Main.
    /// This checks the presenter's identity guard independently of SkinScheduledWork's own cancellation gate.
    private final class LateExecutor: SkinExecutor {
        var work: [() -> Void] = []
        var isCurrent: Bool { Thread.isMainThread }
        func async(_ body: @escaping () -> Void) { work.append(body) }
        func async(after delay: TimeInterval, _ body: @escaping () -> Void) -> SkinScheduledWork {
            work.append(body); return SkinScheduledWork(body)
        }
        func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool, _ body: @escaping () -> Void) -> SkinScheduledWork {
            work.append(body); return SkinScheduledWork(repeats: repeats, body)
        }
    }
}
