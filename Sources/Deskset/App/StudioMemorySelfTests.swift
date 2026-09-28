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
