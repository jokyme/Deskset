import AppKit
import DesksetCore

/// "App: studio memory": what the Studio adds to the app's memory (design §9.5: the Studio's instance, the canvas planes
/// and the thumbnails together at most 30 MB more). The process's physical footprint (`phys_footprint`, what Activity
/// Monitor shows as Memory) is read with the widget on the desktop, after the Studio opened and drew, with the canvas
/// zoomed to 800%, and fitted again. The Studio's window is ordered in off every display, so its views draw (and hold
/// their backing stores) as on screen without being seen.
///
/// The footprint of a whole process moves with everything else it does — the Studio's window, its inspector and code,
/// caches — so it is printed, not checked, unless `DESKSET_STUDIO_MEMORY_BUDGET_MB` makes it a budget.
enum StudioMemorySelfTests {
    /// The process's physical footprint in MB (nan when it cannot be read).
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
    }

    /// Orders `window` in far off every display: its views lay out and draw as on screen (backing stores, layers), and
    /// nobody sees it. It keeps its size.
    static func orderInOffScreen(_ window: NSWindow?) {
        guard let window else { return }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }

    /// Lets the window draw what it was asked to, and the run loop settle (memory given back is given back).
    static func draw(_ window: NSWindow?) {
        window?.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    static func run(_ t: AppTestRunner) {
        rebuildProbe(t)
        closeProbe(t)
        t.suite("App: studio memory") {
            AppSelfTest.stopEarlierSkins()
            let budget = ProcessInfo.processInfo.environment["DESKSET_STUDIO_MEMORY_BUDGET_MB"].flatMap(Double.init)
            for config in ["Deskset\\Calendar", "Audio\\Visualizer"] {
                try measure(t, config: config, budget: budget)
            }
        }
    }

    static func measure(_ t: AppTestRunner, config: String, budget: Double?) throws {
        guard let source = Paths.repositoryFolder("TestSkins"), let app = try AppSelfTest.makeApp(t) else {
            print("    (skipped: TestSkins not found; run from the repository)")
            return
        }
        FriendlyFixtures.fakeDevice(t)
        let root = String(config.split(separator: "\\").first ?? "")
        let destination = app.skinsDirectory.appendingPathComponent(root)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source.appendingPathComponent(root), to: destination)
        app.rescanLibrary()
        guard let c = app.activate(config: config, file: nil) else { return t.check(false, "\(config) loads") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let desktop = footprint()
        app.showInspector(for: c)
        guard let editor = app.inspector else { return t.check(false, "\(config): the editor opens") }
        defer { editor.window?.close() }
        orderInOffScreen(editor.window)
        EditorWindowSelfTests.spin(0.3)
        draw(editor.window)
        let opened = footprint()
        let canvas = editor.canvas
        let fitted = canvas.zoom
        canvas.setZoom(8)
        draw(editor.window)
        let zoomed = footprint()
        canvas.setZoom(fitted)
        draw(editor.window)
        let back = footprint()
        let pane = canvas.enclosingScrollView?.contentSize ?? .zero
        print(String(format: "    MEMORY %@ | desktop %.1f MB | Studio open %+.1f MB | at 800%% %+.1f MB | fitted again %+.1f MB | "
                     + "canvas pane %.0f × %.0f pt", config, desktop, opened - desktop, zoomed - desktop, back - desktop,
                     pane.width, pane.height))
        t.check(editor.window?.isVisible == true, "\(config): the Studio's window is ordered in")
        t.check(opened.isFinite && zoomed.isFinite, "\(config): the footprint is read")
        if let budget {
            t.check(opened - desktop <= budget, "\(config): the Studio adds \(opened - desktop) MB, over \(budget) MB")
            t.check(zoomed - desktop <= budget, "\(config): at 800% the Studio adds \(zoomed - desktop) MB, over \(budget) MB")
        }
    }
}

extension StudioMemorySelfTests {
    final class Weak {
        weak var view: NSView?
        init(_ v: NSView) { view = v }
    }

    /// The inspector built again six times (another layer selected each time), each step drained of what it autoreleased
    /// as the app's event loop drains it after an event: none of the old cards stays alive — nothing holds on to them
    /// (a step made by the self-tests outside any pool keeps what it autoreleased until the suite's pool drains; the
    /// latency suite drains each step's).
    static func rebuildProbe(_ t: AppTestRunner) {
        t.suite("App: studio memory: the inspector's old views go when it is built again") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Calendar") else { return }
            defer { editor.window?.close() }
            guard let skin = editor.skin else { return t.check(false, "skin") }
            let names = skin.meters.prefix(6).map(\.name)
            autoreleasepool {
                editor.select(section: names[0])
                EditorWindowSelfTests.settle()
            }
            var survivors: [Weak] = []
            var fieldCount = 0
            for i in 1...6 {
                var old: [Weak] = []
                autoreleasepool {
                    for v in editor.inspectorStack.arrangedSubviews { old.append(Weak(v)) }
                    fieldCount = 0
                    func walk(_ v: NSView) { if v is NSTextField { fieldCount += 1 }; v.subviews.forEach(walk) }
                    editor.inspectorStack.arrangedSubviews.forEach(walk)
                    editor.select(section: names[i % names.count])
                }
                autoreleasepool { EditorWindowSelfTests.settle() }
                survivors += old.filter { $0.view != nil && $0.view?.window == nil }
            }
            let alive = survivors.compactMap(\.view)
            t.check(fieldCount > 0, "the pages have fields")
            t.check(alive.isEmpty, "the old cards are released: \(alive.map { $0.identifier?.rawValue ?? "\(type(of: $0))" })")
        }
    }

    /// A Studio window opened on a widget, stepped, and closed: once what the close autoreleased is drained, nothing
    /// holds on to its controller, its window or its canvas — a Studio opened and closed again and again does not keep
    /// every window it showed.
    static func closeProbe(_ t: AppTestRunner) {
        t.suite("App: studio memory: a closed Studio window goes") {
            weak var closedEditor: InspectorWindowController?
            weak var closedWindow: NSWindow?
            weak var closedCanvas: SkinCanvasView?
            weak var closedSkin: Skin?
            try autoreleasepool {
                guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Calendar"),
                      let target = editor.skin?.meters.first(where: { $0 is StringMeter })?.name else {
                    return t.check(false, "the Studio opens")
                }
                editor.select(section: target)
                EditorWindowSelfTests.settle()
                editor.commit([.init(section: target, key: "FontSize", value: "21", own: true)], name: "Change Font Size")
                EditorWindowSelfTests.settle()
                editor.window?.undoManager?.undo()
                EditorWindowSelfTests.settle()
                closedEditor = editor
                closedWindow = editor.window
                closedCanvas = editor.canvas
                closedSkin = editor.skin
                editor.window?.close()
                EditorWindowSelfTests.settle()
            }
            for _ in 0..<3 { autoreleasepool { EditorWindowSelfTests.settle() } }
            t.check(closedSkin == nil, "the Studio's instance of the widget is released")
            t.check(closedCanvas == nil, "the canvas is released")
            t.check(closedEditor == nil, "the Studio's window controller is released")
            t.check(closedWindow == nil, "and its window")
        }
    }
}
