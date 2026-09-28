import AppKit
import DesksetCore

/// What is done on a part's page: each row writes its option through the session, as one named step.
extension StudioPartPage {
    // MARK: Data

    /// The data chip: a menu of the data the part can show, and the data's own page.
    func tokenData(_ item: String) {
        guard let m = meter, let skin, let spec = rows[item], case .data(let names) = spec.kind else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(StudioPageView.heading(StudioText[.showsTitle]))
        for name in names where !name.isEmpty {
            guard let measure = skin.measure(named: name) else { continue }
            let title = StudioWords.data(StudioWidgetFacts.dataName(measure, in: skin).name)
            let menuItem = ClosureMenuItem(title) { [weak self] in self?.chooseData(name) }
            menuItem.state = m.measures.first === measure ? .on : .off
            menuItem.image = StudioPageStyle.symbol(StudioWords.symbol(measure), size: 11, weight: .semibold)
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        if let data = liveMeasure(m) {
            menu.addItem(ClosureMenuItem(StudioText[.dataDetails]) { [weak self] in self?.show(data: data.name) })
        }
        guard window.app.presentsWindows, let chip = (window.inspectorController.pageView.itemView(item)
            as? StudioTokenView)?.dataChip else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: chip.bounds.height + 3), in: chip)
    }

    /// Shows another data item in the part (`MeasureName`, the part's own).
    func chooseData(_ name: String) {
        guard let m = meter, let skin, let measure = skin.measure(named: name), m.measures.first !== measure else { return }
        let words = StudioWords.data(StudioWidgetFacts.dataName(measure, in: skin).name)
        let part = partTitle(m, skin: skin)
        let item = rows["shows.token"] != nil ? "shows.token" : "shows.data"
        write("MeasureName", measure.name, of: m, name: StudioText[.undoShows],
              confirm: StudioText.format(.confirmShows, part, words), item: item, section: "shows", elementOnly: true)
    }

    // MARK: Examples, menus, segments, switches

    func example(_ item: String, _ index: Int) {
        guard let m = meter, let skin, let spec = rows[item], case .examples(let presets) = spec.kind,
              presets.indices.contains(index) else { return }
        var ops: [EditOp] = []
        for (key, value) in presets[index].sorted(by: { $0.key < $1.key }) {
            if let value {
                let scope = scope(for: key, of: m)?.scope ?? .element
                ops += WriteScopes.ops(scope, meter: m.name, key: key, value: value, in: skin)
            } else if let op = skin.op(removingOwnOption: key, of: m.name) {
                ops.append(op)
            }
        }
        let shown = (window.inspectorController.pageView.itemView(item) as? StudioExamplesView)?.examples.items
        let words = shown.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? ""
        guard apply(spec.name, ops) else { return }
        confirm(StudioText.format(.confirmOption, spec.title, words), step: spec.name, item: item, section: spec.section,
                change: .value, fromCanvas: false)
    }

    func choose(_ item: String, _ index: Int) {
        guard let m = meter, let skin, let spec = rows[item] else { return }
        switch spec.kind {
        case .fonts(let faces):
            guard faces.indices.contains(index) else { return }
            let face = faces[index]
            write("FontFace", face, of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, StudioFontMenu.title(face)), item: item,
                  section: spec.section)
        case .styles(let list):
            guard list.indices.contains(index) else { return }
            let value = list[index]
            let words = value.isEmpty ? StudioText[.noStyle] : Self.styleWords(value)
            write("MeterStyle", value.isEmpty ? nil : value, of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, words), item: item, section: spec.section,
                  elementOnly: true)
        case .choice(let values):
            guard values.indices.contains(index) else { return }
            let title: String
            if spec.key.caseInsensitiveCompare("FontWeight") == .orderedSame {
                title = Self.weightWords(EditorSchema.fontWeights[index].title)
            } else {
                title = values[index]
            }
            write(spec.key, values[index], of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, title), item: item, section: spec.section)
        case .data(let names):
            guard names.indices.contains(index), !names[index].isEmpty else { return }
            chooseData(names[index])
        case .action:
            // The second item: nothing happens when it is clicked.
            guard index == 1 else { return }
            write("LeftMouseUpAction", nil, of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, StudioText[.clickNothing]), item: item,
                  section: spec.section, change: .revert, elementOnly: true)
        case .shapeKind:
            guard let spec0 = shapeSpec(m) else { return }
            let kinds: [ShapeSpec.Kind] = {
                var list: [ShapeSpec.Kind] = [.rectangle, .ellipse, .line, .arc]
                if !list.contains(spec0.kind) { list.insert(spec0.kind, at: 0) }
                return list
            }()
            guard kinds.indices.contains(index), kinds[index] != spec0.kind else { return }
            writeShape(spec0.withType(kinds[index]), m: m, item: item, spec: spec, words: kinds[index].title)
        default:
            _ = skin
        }
    }

    func segment(_ item: String, _ index: Int) {
        guard let m = meter, let spec = rows[item] else { return }
        switch spec.kind {
        case .align:
            let values = ["Left", "Center", "Right"]
            guard values.indices.contains(index) else { return }
            // The vertical half of the alignment stays as it is.
            let current = (m.option("StringAlign") ?? "Left").trimmingCharacters(in: .whitespaces).lowercased()
            let vertical = ["top", "center", "bottom"].first { v in
                current.hasSuffix(v) && current != v && !(v == "center" && current == "center")
            }
            var value = values[index]
            if let vertical, vertical != "top" { value += vertical.prefix(1).uppercased() + vertical.dropFirst() }
            let words = [StudioText[.alignLeft], StudioText[.alignCenter], StudioText[.alignRight]][index]
            write("StringAlign", value, of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, words), item: item, section: spec.section)
        case .choice(let values):
            guard values.indices.contains(index) else { return }
            write(spec.key, values[index], of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, values[index]), item: item, section: spec.section)
        default: break
        }
    }

    func toggle(_ item: String, _ on: Bool) {
        guard let m = meter, let spec = rows[item] else { return }
        write(spec.key, on ? "1" : "0", of: m, name: spec.name,
              confirm: StudioText.format(.confirmOption, spec.title, on ? StudioText[.onLabel] : "0"), item: item,
              section: spec.section)
    }

    // MARK: Numbers

    func number(_ item: String, part: Int, _ change: StudioNumberChange) {
        guard let m = meter, let spec = rows[item] else { return }
        // A pair (W · H): the second half is H.
        let key = item == "layout.size" ? (part == 0 ? "W" : "H") : spec.key
        switch spec.kind {
        case .fontSize: fontSize(item, m, spec, change)
        case .geometry: geometry(item, key: key, m, spec, change)
        case .number(let minimum, let maximum): plain(item, m, spec, change, minimum: minimum, maximum: maximum)
        case .text:
            if case .typed(let text) = change {
                let words = text.isEmpty ? StudioText[.boxNone] : LayerNaming.quoted(text, limit: 24)
                write(spec.key, text.isEmpty ? nil : text, of: m, name: spec.name,
                      confirm: StudioText.format(.confirmOption, spec.title, words), item: item, section: spec.section)
            } else if case .reset = change {
                write(spec.key, nil, of: m, name: spec.name, confirm: StudioText.format(.confirmReset, spec.title),
                      item: item, section: spec.section, change: .revert)
            }
        case .shapeRadius, .shapeStrokeWidth: shapeNumber(item, m, spec, change)
        default: break
        }
    }

    /// The text size, in points on screen: ±1 an arrow or A− / A+, ±10 with ⇧, a drag of the label, a sum typed.
    private func fontSize(_ item: String, _ m: Meter, _ spec: StudioPartRow, _ change: StudioNumberChange) {
        guard let s = m as? StringMeter else { return }
        let now = TextStyle.pixelSize(points: s.style.fontSize)
        let start = drag?.item == item ? Double(drag!.start) ?? now : now
        func fileValue(_ pt: Double) -> String {
            StudioNumberInput.text((min(max(pt, 1), 400) * 0.75 * 1000).rounded() / 1000)
        }
        func shown(_ pt: Double) -> String { StudioNumberInput.text((min(max(pt, 1), 400) * 2).rounded() / 2) + " pt" }
        switch change {
        case .drag(let delta, let done):
            if drag?.item != item { drag = (item, 0, String(now)) }
            let pt = start + delta
            if done {
                drag = nil
                scrubbingItem = nil
                session?.endPreview()
                write("FontSize", fileValue(pt), of: m, name: spec.name,
                      confirm: StudioText.format(.confirmOption, spec.title, shown(pt)), item: item, section: spec.section)
            } else {
                scrubbingItem = item
                preview("FontSize", fileValue(pt), of: m)
                refreshKeepingDrag()
            }
        case .typed(let text):
            guard let pt = StudioNumberInput.evaluate(text) else { return beep() }
            write("FontSize", fileValue(pt), of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, shown(pt)), item: item, section: spec.section)
        case .step(let d):
            let pt = (now + d).rounded()
            write("FontSize", fileValue(pt), of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, shown(pt)), item: item, section: spec.section)
        case .reset:
            write("FontSize", nil, of: m, name: spec.name, confirm: StudioText.format(.confirmReset, spec.title),
                  item: item, section: spec.section, change: .revert, elementOnly: true)
        }
    }

    /// X, Y, W, H: written as the file writes them (`10R` → `30R`, `(#Gap# + 4)` → `(#Gap# + 24)`), for this part alone.
    private func geometry(_ item: String, key: String, _ m: Meter, _ spec: StudioPartRow, _ change: StudioNumberChange) {
        let raw = m.fileOption(key)
        let name = spec.name
        func confirmText(_ value: String) -> String { StudioText.format(.confirmOption, "\(key)", value) }
        switch change {
        case .drag(let delta, let done):
            if drag?.item != item || drag?.part != (key == "H" ? 1 : 0) { drag = (item, key == "H" ? 1 : 0, raw ?? "") }
            let base = drag?.start ?? ""
            let value = GeometryEdit.offset(base.isEmpty ? nil : base, by: delta)
            if done {
                drag = nil
                scrubbingItem = nil
                session?.endPreview()
                guard delta != 0 else { return refresh() }
                write(key, value, of: m, name: name, confirm: confirmText(value), item: item, section: spec.section,
                      elementOnly: true)
            } else {
                scrubbingItem = item
                preview(key, value, of: m, elementOnly: true)
                refreshKeepingDrag()
            }
        case .typed(let text):
            if text.hasPrefix("#choose:") { return }
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // W and H: back to following the content.
                write(key, nil, of: m, name: name, confirm: StudioText.format(.confirmOption, key, StudioText[.fit]),
                      item: item, section: spec.section, elementOnly: true)
                return
            }
            // A sum is worked out; anything else (10R, a formula of the widget's own) is written as it is.
            let isSum = t.unicodeScalars.contains { "+*/".unicodeScalars.contains($0) } && !t.hasPrefix("(")
            let value = isSum ? StudioNumberInput.evaluate(t).map(GeometryEdit.format) ?? t : t
            write(key, value, of: m, name: name, confirm: confirmText(value), item: item, section: spec.section,
                  elementOnly: true)
        case .step(let d):
            let value = GeometryEdit.offset(raw, by: d)
            write(key, value, of: m, name: name, confirm: confirmText(value), item: item, section: spec.section,
                  elementOnly: true)
        case .reset:
            write(key, nil, of: m, name: name, confirm: StudioText.format(.confirmReset, key), item: item,
                  section: spec.section, change: .revert, elementOnly: true)
        }
    }

    private func plain(_ item: String, _ m: Meter, _ spec: StudioPartRow, _ change: StudioNumberChange,
                       minimum: Double?, maximum: Double?) {
        let now = OptionValue.number(m.option(spec.key) ?? "") ?? 0
        func clamp(_ v: Double) -> Double { min(max(v, minimum ?? -.infinity), maximum ?? .infinity) }
        func text(_ v: Double) -> String { StudioNumberInput.text(clamp(v)) }
        switch change {
        case .drag(let delta, let done):
            if drag?.item != item { drag = (item, 0, String(now)) }
            let v = (Double(drag?.start ?? "") ?? now) + delta
            if done {
                drag = nil
                scrubbingItem = nil
                session?.endPreview()
                write(spec.key, text(v), of: m, name: spec.name,
                      confirm: StudioText.format(.confirmOption, spec.title, text(v)), item: item, section: spec.section)
            } else {
                scrubbingItem = item
                preview(spec.key, text(v), of: m)
                refreshKeepingDrag()
            }
        case .typed(let t):
            guard let v = StudioNumberInput.evaluate(t) else {
                // Not a number: the widget's own formula or variable, written as it is.
                let trimmed = t.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    write(spec.key, nil, of: m, name: spec.name, confirm: StudioText.format(.confirmReset, spec.title),
                          item: item, section: spec.section, change: .revert, elementOnly: true)
                    return
                }
                write(spec.key, trimmed, of: m, name: spec.name,
                      confirm: StudioText.format(.confirmOption, spec.title, trimmed), item: item, section: spec.section)
                return
            }
            write(spec.key, text(v), of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, text(v)), item: item, section: spec.section)
        case .step(let d):
            write(spec.key, text(now + d), of: m, name: spec.name,
                  confirm: StudioText.format(.confirmOption, spec.title, text(now + d)), item: item, section: spec.section)
        case .reset:
            write(spec.key, nil, of: m, name: spec.name, confirm: StudioText.format(.confirmReset, spec.title),
                  item: item, section: spec.section, change: .revert, elementOnly: true)
        }
    }

    /// During a drag the page shows the value as it goes, without making a step.
    private func refreshKeepingDrag() {
        refresh()
    }

    private func beep() {
        if window.app.presentsWindows { NSSound.beep() }
    }

    // MARK: Shapes (compatibility mode: `ShapeSpec` keeps what it does not change as written)

    func writeShape(_ spec: ShapeSpec, m: Meter, item: String, spec row: StudioPartRow, words: String) {
        write("Shape", spec.text, of: m, name: row.name, confirm: StudioText.format(.confirmOption, row.title, words),
              item: item, section: row.section, elementOnly: true)
    }

    private func shapeNumber(_ item: String, _ m: Meter, _ row: StudioPartRow, _ change: StudioNumberChange) {
        guard var spec = shapeSpec(m) else { return }
        let isRadius: Bool = { if case .shapeRadius = row.kind { return true }; return false }()
        let current: Double = isRadius ? (spec.number(4) ?? OptionValue.number(m.skin.resolve(spec.param(4) ?? "0", in: m,
            sectionVariables: false)) ?? 0) : (spec.modifiers.compactMap { mod -> Double? in
            if case .strokeWidth(let w) = mod { return Double(w) }
            return nil
        }.last ?? 1)
        var target: Double?
        switch change {
        case .drag(let delta, let done):
            guard done else { return }
            target = current + delta
        case .typed(let t): target = StudioNumberInput.evaluate(t)
        case .step(let d): target = current + d
        case .reset: target = isRadius ? 0 : 1
        }
        guard let v = target.map({ max($0, 0) }) else { return beep() }
        let text = StudioNumberInput.text(v)
        if isRadius { spec.setParam(4, text) } else { spec.setStrokeWidth(text) }
        writeShape(spec, m: m, item: item, spec: row, words: text)
    }

    func openShapeColor(_ item: String, _ m: Meter) {
        guard let skin, let spec = shapeSpec(m), let row = rows[item] else { return }
        let fill = item == "shape.fill"
        let paint = spec.modifiers.compactMap { mod -> ShapeSpec.Paint? in
            if fill, case .fill(let p) = mod { return p }
            if !fill, case .stroke(let p) = mod { return p }
            return nil
        }.last
        let written: String = { if case .color(let c)? = paint { return c }; return "0,0,0" }()
        let current = OptionValue.color(m.skin.resolve(written, in: m, sectionVariables: false))
            ?? RGBA(r: 0, g: 0, b: 0, a: 0)
        closePopover()
        window.canvasController.overlay.clearFramesNow()
        activeSwatch = item
        let popover = StudioColorPopover(target: .init(title: row.title, color: current, written: written, parts: 1,
                                                       acceptsAlpha: true),
                                         widgetColors: StudioCanvasOverlay.colors(of: skin),
                                         presentsWindows: window.app.presentsWindows)
        popover.onClose = { [weak self] c, name in
            guard let self else { return }
            self.colorPopover = nil
            self.activeSwatch = nil
            guard let c, var s = self.shapeSpec(m) else { return self.refresh() }
            let text = StudioColorWriting.text(c, like: written, acceptsAlpha: true)
            if fill { s.setFill(.color(text)) } else { s.setStroke(.color(text)) }
            let words = name.map(StudioWords.color) ?? StudioWords.color(LayerNaming.colorName(c))
            self.writeShape(s, m: m, item: item, spec: row, words: words)
        }
        popover.anchorItem = item
        _ = popover.view
        colorPopover = popover
        refresh()
        if window.app.presentsWindows, window.window?.isVisible == true,
           let anchor = window.inspectorController.pageView.swatchView(item: item, swatch: item) {
            popover.show(relativeTo: anchor.bounds, of: anchor)
        }
    }
}
