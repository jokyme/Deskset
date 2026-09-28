// What happens to a partitioned window when its color space changes (a window moving to a screen with another color
// space, or the display's color profile changed in System Settings). The partition's base bitmap is drawn in the
// window's color space and the group layers copy their base pixels from it; when the space changes, Core Animation
// draws the E layers again in the new space, possibly on the main thread (question 4 saw CA call draw(in:) on the
// main thread when a layer's first display came before the window's context knew its color space), while the base
// bitmap stays in the old one until the runtime draws it again.
//
//   cschange [--to srgb|p3] [--react]      changes both windows' NSWindow.colorSpace itself (a stand-in for a screen
//                                           change: the only way to change it without touching System Settings)
//   cschange --wait S [--react]             changes nothing; runs S seconds while a person changes the display's color
//                                           profile (System Settings → Displays → Color profile), and records the same
//
// Two windows side by side, both in the default window color space, System widget at tick 7, not updating: the
// partition with its base bitmap in the window's space (EPw) and one E layer (E1). Every 0.25 s both are read back
// and compared (partition vs one layer: 7 px before any change). Every draw(in:) is logged with its thread and its
// context's color space. --react: the runtime's answer, as the plan has it — on the change, the skin thread draws the
// base bitmap again in the new space and redraws every group (one transaction).
import AppKit

func colorSpaceChange() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let react = flag("--react")
    let wait = Double(option("--wait") ?? "")
    let target = choice("--to", WindowSpace.srgb)
    let widget = Widgets.system()
    var partitionConfig = Config(mode: .EP)
    partitionConfig.baseInWindowSpace = true
    let configs = [partitionConfig, Config(mode: .E1)]
    var threads: [RunLoopThread] = []
    var windows: [SkinWindow] = []
    for (i, c) in configs.enumerated() {
        threads.append(RunLoopThread.make("skin \(i)"))
        let w = SkinWindow(widget, c, origin: gridOrigin(i, size: widget.size, columns: 2), thread: threads[i])
        w.buildAndCommit(tick: 7)
        w.show()
        windows.append(w)
    }
    pump(1.5)
    var j: JSON = ["react": react, "widget": "system, tick 7, not updating", "windows": ["EPw", "E1"]]
    func spaceNames() -> [String] {
        windows.map { ($0.panel.colorSpace?.localizedName ?? "none") + " / screen " + ($0.panel.screen?.colorSpace?.localizedName ?? "none") }
    }
    j["colorSpacesAtStart"] = spaceNames()
    var reference: [Pixels] = []
    for w in windows { if let img = captureWindow(w.panel) { reference.append(Pixels.of(img)) } }
    guard reference.count == 2 else { return ["error": "capture failed"] }
    j["partitionVsOneLayerBefore"] = compare(reference[0], reference[1]).json

    // Notifications the runtime would react to.
    var notes: [JSON] = []
    let center = NotificationCenter.default
    var observers: [NSObjectProtocol] = []
    for name in [NSWindow.didChangeScreenProfileNotification, NSWindow.didChangeBackingPropertiesNotification,
                 NSWindow.didChangeScreenNotification] {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, windows.contains(where: { $0.panel === w }) else { return }
            notes.append(["atMs": r(now() * 1000, 1), "name": n.name.rawValue,
                          "window": windows.firstIndex { $0.panel === w } ?? -1,
                          "colorSpace": w.colorSpace?.localizedName ?? "none"])
            if react && n.name == NSWindow.didChangeScreenProfileNotification {
                for x in windows where x.panel === w { x.onSkin { x.redrawForColorSpaceChange() } }
            }
        })
    }
    drawEvents.recording = true
    var timeline: [JSON] = []
    func sample(_ label: String) {
        var shots: [Pixels] = []
        for w in windows { if let img = captureWindow(w.panel) { shots.append(Pixels.of(img)) } }
        guard shots.count == 2 else { return }
        let d = compare(shots[0], shots[1])
        timeline.append(["atMs": r(now() * 1000, 1), "phase": label,
                         "partitionVsOneLayer": ["max": d.maxChannel, "pixels": d.differing],
                         "partitionVsItselfBefore": compare(shots[0], reference[0]).differing,
                         "oneLayerVsItselfBefore": compare(shots[1], reference[1]).differing])
    }
    let t0 = now()
    if let wait {
        j["mode"] = "waiting \(Int(wait)) s for a person to change the display's color profile"
        log("cschange: change the display's color profile now (System Settings → Displays → Color profile); "
            + "\(Int(wait)) s")
        let end = now() + wait
        while now() < end {
            sample("waiting")
            pump(0.25)
        }
    } else {
        j["mode"] = "NSWindow.colorSpace set to \(target.rawValue) by the program, then back to the screen's"
        for _ in 0..<4 { sample("before"); pump(0.25) }
        let tSwitch = now()
        for w in windows { if let cs = nsColorSpace(target, screen: w.panel.screen) { w.panel.colorSpace = cs } }
        if react { for w in windows { w.onSkin { w.redrawForColorSpaceChange() } } }
        for _ in 0..<16 { sample("after switching to \(target.rawValue)"); pump(0.25) }
        let tBack = now()
        for w in windows { if let cs = w.panel.screen?.colorSpace { w.panel.colorSpace = cs } }
        if react { for w in windows { w.onSkin { w.redrawForColorSpaceChange() } } }
        for _ in 0..<16 { sample("after switching back"); pump(0.25) }
        j["switchAtMs"] = r(tSwitch * 1000, 1)
        j["switchBackAtMs"] = r(tBack * 1000, 1)
        j["drawsBeforeSwitch"] = drawEvents.summary(from: t0, to: tSwitch)
        j["drawsAfterSwitch"] = drawEvents.summary(from: tSwitch, to: tBack)
        j["drawsAfterSwitchBack"] = drawEvents.summary(from: tBack)
    }
    j["draws"] = drawEvents.summary(from: t0)
    drawEvents.recording = false
    j["colorSpacesAtEnd"] = spaceNames()
    j["notifications"] = notes
    // The timeline, only where something changed.
    var compact: [JSON] = []
    var last = ""
    for e in timeline {
        let key = "\(e["phase"]!) \(e["partitionVsOneLayer"]!) \(e["partitionVsItselfBefore"]!) \(e["oneLayerVsItselfBefore"]!)"
        if key != last { compact.append(e) }
        last = key
    }
    j["timeline"] = compact
    j["samples"] = timeline.count
    for o in observers { center.removeObserver(o) }
    for w in windows { w.close() }
    for t in threads { t.stop() }
    return j
}
