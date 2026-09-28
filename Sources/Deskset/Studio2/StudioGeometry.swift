import AppKit
import DesksetCore

/// Moving and resizing parts on the canvas: the frames the drag asks for become X / Y / W / H written the way the
/// file writes them (`GeometryEdit`: `10R` → `30R`, `(#Gap# + 4)` → `(#Gap# + 24)`), in each part's own section; the
/// drag previews through the session and makes one step on release, confirmed at the top of the inspector. Arrow keys
/// nudge (⇧ ten points) and make one step after a short pause.
final class StudioGeometry {
    unowned let window: StudioWindowController

    private struct Base {
        var meter: String
        var raw: (x: String?, y: String?, w: String?, h: String?)
        var frame: SkinRect
        var content: (width: Double, height: Double)
    }

    private var bases: [Base] = []
    private var values: [String: [String: String]] = [:]
    private var resizing = false
    private var nudge = (dx: 0.0, dy: 0.0)
    private var nudgeTimer: Timer?
    /// The pause after the last arrow key before the nudges become one step.
    static let nudgePause: TimeInterval = 0.7

    init(window: StudioWindowController) {
        self.window = window
    }

    var skin: Skin? { window.skin }
    var session: EditingSession? { window.session }
    var isActive: Bool { !bases.isEmpty }

    func begin(_ names: [String], resize: Bool) {
        commitNudge()
        guard let skin else { return }
        let wanted = Set(names.map { $0.lowercased() })
        bases = skin.meters.filter { wanted.contains($0.name.lowercased()) }.map {
            Base(meter: $0.name, raw: $0.rawGeometry, frame: $0.frame, content: $0.contentSize)
        }
        values = [:]
        resizing = resize
        window.canvasController.canvas.followers = SkinCanvasView.followers(of: bases.map(\.meter), in: skin)
    }

    /// The frames the gesture wants, previewed: each part in file order, corrected by where it really lands (a part
    /// placed after a moved one, `0R`, moves with it and is not moved twice).
    func preview(_ targets: [String: SkinRect]) {
        guard let skin, let session else { return }
        for base in bases {
            guard let target = targets[base.meter], let m = skin.meter(named: base.meter) else { continue }
            let f = base.frame
            let dw = target.width - f.width, dh = target.height - f.height
            let previous = values[base.meter] ?? [:]
            func compute(_ dx: Double, _ dy: Double) -> [String: String] {
                var v: [String: String] = [:]
                func set(_ key: String, _ raw: String?, _ delta: Double, fallback: Double?) {
                    if delta != 0 {
                        if let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                            v[key] = GeometryEdit.offset(raw, by: delta)
                        } else if let fallback {
                            v[key] = GeometryEdit.format(fallback + delta)
                        } else {
                            v[key] = GeometryEdit.offset(raw, by: delta)
                        }
                    } else if previous[key] != nil {
                        v[key] = raw ?? ""
                    }
                }
                set("W", base.raw.w, dw, fallback: base.content.width)
                set("H", base.raw.h, dh, fallback: base.content.height)
                set("X", base.raw.x, dx, fallback: nil)
                set("Y", base.raw.y, dy, fallback: nil)
                return v
            }
            // Whole points: the canvas rounds the frames it asks for, and a centred text's frame sits on a half point —
            // that half point is not a move (a drag across must not rewrite Y).
            var dx = (target.x - f.x).rounded(.toNearestOrEven), dy = (target.y - f.y).rounded(.toNearestOrEven)
            var v = compute(dx, dy)
            session.preview(section: base.meter, v)
            var ex = target.x - m.frame.x, ey = target.y - m.frame.y
            ex = abs(ex) >= 1 ? ex.rounded() : 0
            ey = abs(ey) >= 1 ? ey.rounded() : 0
            if ex != 0 || ey != 0 {
                dx += ex
                dy += ey
                let first = v
                v = compute(dx, dy)
                var shown = v
                let written: [String: String?] = ["X": base.raw.x, "Y": base.raw.y, "W": base.raw.w, "H": base.raw.h]
                for key in first.keys where v[key] == nil { shown[key] = (written[key] ?? nil) ?? "" }
                session.preview(section: base.meter, shown)
            }
            values[base.meter] = v
        }
        window.canvasController.canvas.needsDisplay = true
        window.canvasController.overlay.needsDisplay = true
    }

    /// Ends the gesture: what it previewed is written as one step (`keep`), confirmed at the top of the inspector.
    func end(keep: Bool) {
        guard !bases.isEmpty else { return }
        let bases = self.bases
        self.bases = []
        let all = values
        values = [:]
        window.canvasController.canvas.followers = [:]
        session?.endPreview()
        guard keep, let skin else { return }
        var ops: [EditOp] = []
        for base in bases {
            let v = all[base.meter] ?? [:]
            let raw: [String: String?] = ["X": base.raw.x, "Y": base.raw.y, "W": base.raw.w, "H": base.raw.h]
            for key in ["X", "Y", "W", "H"] {
                guard let value = v[key], value != ((raw[key] ?? nil) ?? "") else { continue }
                ops += WriteScopes.ops(.element, meter: base.meter, key: key, value: value, in: skin)
            }
        }
        guard !ops.isEmpty else { return }
        let names = bases.map(\.meter)
        let label = names.count == 1 ? window.partPage.partTitle(skin.meter(named: names[0])!, skin: skin)
            : StudioText.format(.partsCount, names.count)
        let step = resizing ? StudioText[.undoPartSize] : StudioText[.undoMove]
        guard window.partPage.apply(step, ops) else { return }
        let text = resizing ? StudioText.format(.confirmOption, StudioText[.rowSize], label)
            : StudioText.format(.confirmMoved, label)
        window.partPage.confirm(text, step: step, item: "layout.x", section: "layout",
                                change: names.count > 1 ? .beyondSelection : .value, fromCanvas: true)
    }

    /// An arrow key on the canvas: the selection moves at once (a preview); the step is made after a pause.
    func nudge(dx: Double, dy: Double) {
        let names = window.canvasController.canvas.selectedNames
        guard !names.isEmpty, let skin else { return }
        if bases.isEmpty {
            begin(names, resize: false)
            nudge = (0, 0)
        }
        nudge.dx += dx
        nudge.dy += dy
        var targets: [String: SkinRect] = [:]
        for base in bases {
            var f = base.frame
            f.x += nudge.dx
            f.y += nudge.dy
            targets[base.meter] = f
        }
        preview(targets)
        _ = skin
        nudgeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.nudgePause, repeats: false) { [weak self] _ in self?.commitNudge() }
        RunLoop.main.add(timer, forMode: .common)
        nudgeTimer = timer
    }

    /// Writes a run of arrow keys now.
    func commitNudge() {
        guard nudgeTimer != nil else { return }
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        end(keep: true)
    }

    func cancel() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        bases = []
        values = [:]
        session?.endPreview()
    }
}
