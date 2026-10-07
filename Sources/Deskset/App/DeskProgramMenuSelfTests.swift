import AppKit
import DesksetCore

enum DeskProgramMenuSelfTests {
    private typealias P = DeskProgramMenus
    private enum Failure: Error { case fixture }
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    private struct Fixture {
        let view: NSView
        let window: NSWindow
        let presenter: P
    }
    private final class TrackingState {
        weak var presenter: P?
        var item: NSMenuItem?
    }
    private final class NativeReceiver: NSObject {
        var calls = 0
        var represented: AnyObject?
        @objc func invoke(_ sender: NSMenuItem) {
            calls += 1; represented = sender.representedObject as AnyObject?
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk menus: resolved native rows preserve nesting checks enabled text and source item identities") {
            let f = fixture(t)
            let first = id("child", [0]), disabled = id("child", [1]), nested = id("root", [2, 0])
            let longTitle = "Charging — 当前电量 🔋 " + String(repeating: "native title ", count: 5)
            let nodes: [ProgramMenuSnapshot.Node] = [
                .item(id: first, title: longTitle, checked: true, enabled: true),
                .item(id: disabled, title: "Unavailable", checked: false, enabled: false),
                .divider,
                .submenu(title: "More", items: [
                    .item(id: nested, title: "Chosen", checked: true, enabled: true),
                    .submenu(title: "Empty", items: [])]),
                .item(id: id("child", [3]), title: "", checked: false, enabled: true)
            ]
            var selected: [ProgramMenuItemID] = [], cancelled: [P.Request] = []
            guard let request = f.presenter.begin(at: NSPoint(x: 20, y: 30), onCancel: { cancelled.append($0) }) else { throw Failure.fixture }
            f.presenter.present(nodes, for: request) { selected.append($0) }
            guard let menu = f.presenter.menu, let submenu = menu.items[3].submenu else { throw Failure.fixture }
            t.equal(menu.numberOfItems, 5, "Desk rows are not regrouped using the INI three-item rule")
            t.equal(menu.items[0].title, longTitle, "no INI title truncation")
            t.equal(menu.items[0].state, .on); t.equal(menu.items[1].state, .off)
            t.check(!menu.items[1].isEnabled); t.check(menu.items[2].isSeparatorItem)
            t.equal(menu.items[4].title, ""); t.equal(submenu.title, "More")
            t.equal(submenu.items[0].state, .on); t.equal(submenu.items[1].submenu?.numberOfItems, 0)
            var pending = [menu]
            while let value = pending.popLast() {
                t.check(!value.autoenablesItems)
                for item in value.items {
                    t.equal(item.keyEquivalent, "")
                    if let child = item.submenu { pending.append(child) }
                }
            }
            menu.update(); submenu.update(); t.check(!menu.items[1].isEnabled)
            menu.items[1].isEnabled = true
            t.check(perform(menu.items[1])); t.equal(selected, [], "snapshot-disabled cannot be enabled by changing its NSMenuItem")
            let forged = NSMenuItem(title: "Chosen", action: submenu.items[0].action, keyEquivalent: "")
            forged.target = submenu.items[0].target
            t.check(perform(forged)); t.equal(selected, [], "the actual built item is part of selection identity")
            t.check(perform(submenu.items[0])); t.equal(selected, [nested]); t.equal(cancelled, [])
            t.check(f.presenter.currentRequest == nil && f.presenter.menu == nil)
            t.check(perform(submenu.items[0])); t.check(perform(menu.items[0])); t.equal(selected, [nested])
            t.check(!f.window.isVisible && !f.presenter.isTracking)
        }

        t.suite("App: Desk menus: selection survives either delegate close order and tracking return retires unselected items") {
            for closeFirst in [false, true] {
                let state = TrackingState(), point = NSPoint(x: -25, y: -10), selectedID = id("card", [0])
                var cancelled = 0, selected: [ProgramMenuItemID] = []
                let f = fixture(t, track: { menu, anchor, view in
                    t.equal(anchor, point); t.equal(view.bounds.origin, NSPoint(x: -40, y: -30))
                    t.check(state.presenter?.isTracking == true && view.window?.isVisible == false)
                    state.item = menu.items[0]
                    if closeFirst { menu.delegate?.menuDidClose?(menu) }
                    t.check(perform(menu.items[0])); t.check(perform(menu.items[0]))
                    if !closeFirst { menu.delegate?.menuDidClose?(menu) }
                    return true
                })
                state.presenter = f.presenter
                f.view.bounds = NSRect(x: -40, y: -30, width: 100, height: 60)
                guard let request = f.presenter.begin(at: point, onCancel: { _ in cancelled += 1 }) else { throw Failure.fixture }
                f.presenter.present([node(selectedID)], for: request) { selected.append($0) }
                t.equal(selected, [selectedID]); t.equal(cancelled, 0)
                t.check(f.presenter.currentRequest == nil && !f.presenter.isTracking)
                t.check(perform(state.item)); t.equal(selected, [selectedID])
                f.presenter.close(); t.equal(cancelled, 0, "closing after selection cannot cancel its pending owner action")
            }

            let state = TrackingState()
            var cancelled = 0, selections = 0
            let f = fixture(t, track: { menu, _, _ in
                state.item = menu.items[0]
                menu.delegate?.menuDidClose?(menu)
                return false
            })
            guard let request = f.presenter.begin(at: NSPoint(x: 10, y: 10), onCancel: { _ in cancelled += 1 }) else { throw Failure.fixture }
            f.presenter.present([node(id("card", [0]))], for: request) { _ in selections += 1 }
            t.equal(cancelled, 1); t.check(f.presenter.currentRequest == nil)
            t.check(perform(state.item)); f.presenter.cancel(); t.equal(cancelled, 1); t.equal(selections, 0)
        }

        t.suite("App: Desk menus: async replies replacement reentrancy window changes and close preserve the newest request") {
            let f = fixture(t), other = fixture(t), point = NSPoint(x: 10, y: 10)
            var cancelled: [P.Request] = [], selections = 0
            guard let first = f.presenter.begin(at: point, onCancel: { cancelled.append($0) }),
                  let foreign = other.presenter.begin(at: point),
                  let second = f.presenter.begin(at: point, onCancel: { cancelled.append($0) }) else { throw Failure.fixture }
            t.equal(first.serial, foreign.serial); t.check(first != foreign)
            t.check(second.serial > first.serial); t.equal(cancelled, [first])
            f.presenter.present([node(id("old", [0]))], for: first) { _ in selections += 100 }
            f.presenter.present([node(id("foreign", [0]))], for: foreign) { _ in selections += 100 }
            t.check(f.presenter.menu == nil); t.equal(f.presenter.currentRequest, second)
            f.presenter.present([node(id("current", [0]))], for: second) { _ in selections += 1 }
            guard let held = f.presenter.menu?.items.first else { throw Failure.fixture }
            f.presenter.cancel(); t.equal(cancelled, [first, second])
            t.check(perform(held)); t.equal(selections, 0)

            guard let moved = f.presenter.begin(at: point, onCancel: { cancelled.append($0) }) else { throw Failure.fixture }
            let replacementWindow = NSWindow(contentRect: f.window.frame, styleMask: .borderless, backing: .buffered, defer: false)
            replacementWindow.isReleasedWhenClosed = false
            t.atSuiteEnd { replacementWindow.close() }
            replacementWindow.contentView = f.view
            f.presenter.present([node(id("moved", [0]))], for: moved) { _ in selections += 1 }
            t.equal(cancelled, [first, second, moved]); t.check(f.presenter.menu == nil)
            t.check(f.presenter.begin(at: NSPoint(x: CGFloat.nan, y: 1)) == nil)
            t.check(f.presenter.begin(at: NSPoint(x: 201, y: 1)) == nil)
            f.view.isHidden = true; t.check(f.presenter.begin(at: point) == nil); f.view.isHidden = false
            let live = P(view: f.view)
            t.check(live.begin(at: point) == nil, "production does not open on an ordered-out parent")
            live.close()
            guard let closing = f.presenter.begin(at: point, onCancel: { cancelled.append($0) }) else { throw Failure.fixture }
            f.presenter.close()
            f.presenter.present([node(id("late", [0]))], for: closing) { _ in selections += 1 }
            t.equal(cancelled.last, closing); t.check(f.presenter.begin(at: point) == nil); t.equal(selections, 0)

            var replacement: P.Request?, cancellations = 0
            let state = TrackingState()
            let reentrant = fixture(t, track: { menu, _, _ in
                t.check(perform(menu.items[0]))
                menu.delegate?.menuDidClose?(menu)
                return true
            })
            state.presenter = reentrant.presenter
            guard let request = reentrant.presenter.begin(at: point, onCancel: { _ in cancellations += 1 }) else { throw Failure.fixture }
            reentrant.presenter.present([node(id("reentrant", [0]))], for: request) { _ in
                replacement = state.presenter?.begin(at: point, onCancel: { _ in cancellations += 1 })
            }
            t.check(replacement != nil); t.equal(reentrant.presenter.currentRequest, replacement)
            t.equal(cancellations, 0, "returning from old tracking cannot retire a newer request")
            reentrant.presenter.cancel(); t.equal(cancellations, 1)
        }

        t.suite("App: Desk menus: native actions retire custom leases once and preserve targets payloads and nested state") {
            let f = fixture(t), receiver = NativeReceiver(), marker = NSObject(), point = NSPoint(x: 10, y: 10)
            var cancelled = 0, programSelections = 0
            let native = NSMenuItem(title: "Remove", action: #selector(NativeReceiver.invoke(_:)), keyEquivalent: "")
            native.target = receiver; native.representedObject = marker; native.state = .on
            let disabled = NSMenuItem(title: "Disabled", action: #selector(NativeReceiver.invoke(_:)), keyEquivalent: "")
            disabled.target = receiver; disabled.isEnabled = false
            let holder = NSMenuItem(title: "Widget", action: nil, keyEquivalent: ""), submenu = NSMenu(title: "Widget")
            submenu.addItem(native); submenu.addItem(disabled); holder.submenu = submenu
            guard let request = f.presenter.begin(at: point, onCancel: { _ in
                cancelled += 1; t.equal(receiver.calls, 0); t.check(f.presenter.currentRequest == nil)
            }) else { throw Failure.fixture }
            f.presenter.present([node(id("program", [0]))], for: request, nativeItems: [holder]) { _ in programSelections += 1 }
            guard let menu = f.presenter.menu else { throw Failure.fixture }
            t.equal(menu.numberOfItems, 3); t.check(menu.items[1].isSeparatorItem)
            t.check(!menu.autoenablesItems && !submenu.autoenablesItems)
            t.equal(native.state, .on); t.check((native.representedObject as AnyObject?) === marker)
            t.check(!disabled.isEnabled); disabled.isEnabled = true
            t.check(perform(disabled)); t.equal(receiver.calls, 0); t.equal(cancelled, 0)
            t.check(perform(native)); t.equal(receiver.calls, 1); t.equal(cancelled, 1)
            t.check(receiver.represented === marker); t.equal(programSelections, 0)
            t.check(f.presenter.currentRequest == nil)
            t.check(perform(native)); t.check(perform(menu.items[0])); t.equal(receiver.calls, 1); t.equal(programSelections, 0)
            f.presenter.cancel(); t.equal(cancelled, 1)

            let occupied = NSMenu(title: "Other"), reused = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
            occupied.addItem(reused)
            guard let refused = f.presenter.begin(at: point, onCancel: { _ in cancelled += 1 }) else { throw Failure.fixture }
            f.presenter.present([], for: refused, nativeItems: [reused]) { _ in programSelections += 1 }
            t.equal(cancelled, 2); t.check(f.presenter.currentRequest == nil)
            t.check(reused.menu === occupied, "a caller-owned menu is never dismantled")

            guard let empty = f.presenter.begin(at: point, onCancel: { _ in cancelled += 1 }) else { throw Failure.fixture }
            f.presenter.present([], for: empty) { _ in programSelections += 1 }
            t.equal(cancelled, 3); t.check(f.presenter.currentRequest == nil && f.presenter.menu == nil)
            t.equal(programSelections, 0, "an empty resolved list does not invent a custom command")
        }
    }

    private static func id(_ owner: String, _ path: [Int]) -> ProgramMenuItemID {
        ProgramMenuItemID(owner: ElementID(name: owner, index: owner == "root" ? 0 : 1), path: path)
    }

    private static func node(_ id: ProgramMenuItemID) -> ProgramMenuSnapshot.Node {
        .item(id: id, title: "Action", checked: false, enabled: true)
    }

    @discardableResult
    private static func perform(_ item: NSMenuItem?) -> Bool {
        guard let item, let action = item.action else { return false }
        return NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    private static func fixture(_ t: AppTestRunner, track: P.Tracking? = nil) -> Fixture {
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let window = NSWindow(contentRect: NSRect(x: -300, y: -200, width: 200, height: 120),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        let presenter = P(view: view, presentsWindows: false, trackMenu: track)
        t.atSuiteEnd { presenter.close(); window.close() }
        return Fixture(view: view, window: window, presenter: presenter)
    }
}
