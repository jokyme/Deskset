import AppKit
import DesksetCore

/// The "Shapes" card of a Shape meter (docs/editor-design.md §4): the meter's `Shape`, `Shape2`… as a list (icon +
/// "Rounded rectangle 120 × 48"), with add / remove / move up / move down (renumbering rewrites Combine references),
/// and the selected shape expanded: Type (converting keeps the geometry and the modifiers), Geometry fields for the
/// type, Fill (None | Color | Linear | Radial gradient — gradients edit their named option), Stroke (on/off, color,
/// width, dashes; caps and join folded), Transform (folded). Parameters written as formulas or variables are pills and
/// are never lost; a shape the model cannot read is shown as such, with a way to the code.
///
/// The view is rebuilt from the skin after every write, like the rest of the inspector; every write goes through the
/// controller (one undo step each). The editing operations are the controller extension below, so self-tests can use
/// them without the view.
final class ShapeEditorView: NSStackView {
    weak var controller: InspectorWindowController?
    let meter: String
    let items: [ShapeItem]
    /// The option key of the expanded shape.
    let selectedKey: String?

    /// One `Shape` / `ShapeN` option of the meter.
    struct ShapeItem {
        var key: String
        var index: Int
        var row: InspectorWindowController.Row
        /// As written (nil when the model cannot read it).
        var spec: ShapeSpec?
        /// With variables and section values resolved: the numbers the engine uses.
        var resolved: ShapeSpec?
    }

    /// Shown under the SHAPE card's own rows (its "More Shape Options"): what those rows show — the parts, type, fill
    /// color, outline color, thickness and dashes — isn't repeated; the exact geometry, a gradient's stops, caps and
    /// join, and transforms are.
    let essentialsAbove: Bool

    init(controller: InspectorWindowController, meter: String, essentialsAbove: Bool = false) {
        self.controller = controller
        self.meter = meter
        self.essentialsAbove = essentialsAbove
        items = controller.shapeItems(of: meter)
        let remembered = controller.inspectorState.expandedShapes[meter.lowercased()]
        selectedKey = items.first { $0.key.caseInsensitiveCompare(remembered ?? "") == .orderedSame }?.key ?? items.first?.key
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        identifier = NSUserInterfaceItemIdentifier("Shape")
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var selected: ShapeItem? { items.first { $0.key == selectedKey } }

    // MARK: Building

    private func fill(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func build() {
        if !essentialsAbove {
            let list = EditorStyle.vstack(items.map(listRow), spacing: 2)
            for v in list.arrangedSubviews { v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
            if items.isEmpty {
                list.addArrangedSubview(EditorStyle.label("No shapes yet — add one below.", size: 11.5, color: .secondaryLabelColor))
            }
            fill(list)
        }
        fill(toolbar())
        guard let item = selected else { return }
        let divider = NSBox()
        divider.boxType = .separator
        fill(divider)
        fill(detail(item))
    }

    /// A list entry: icon, summary, a dot of its fill color; the selected one highlighted.
    private func listRow(_ item: ShapeItem) -> NSView {
        let isSelected = item.key == selectedKey
        let kind = item.spec?.unknownType == nil ? item.spec?.kind : nil
        let icon = NSImageView(image: EditorStyle.image(kind?.symbol ?? "exclamationmark.triangle", size: 12) ?? NSImage())
        icon.contentTintColor = kind == nil ? .systemOrange : (isSelected ? .controlAccentColor : .secondaryLabelColor)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let title = EditorStyle.label(Self.summary(item), size: 12, weight: isSelected ? .semibold : .regular)
        let number = EditorStyle.mono("\(item.index)", size: 10, color: .tertiaryLabelColor)
        number.toolTip = item.key
        // In a narrow column the summary is shortened, the number stays whole (at one priority, either could be).
        number.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        var parts: [NSView] = [icon, title, EditorStyle.spacer()]
        if let rgba = item.resolved?.fill?.rgba {
            let dot = SwatchDot(color: rgba)
            parts.append(dot)
        }
        parts.append(number)
        let row = ClickableRow(parts, selected: isSelected)
        row.identifier = NSUserInterfaceItemIdentifier("shape-row-\(item.key)")
        row.toolTip = item.row.raw
        row.setAccessibilityLabel("\(item.key): \(Self.summary(item))")
        let key = item.key, meter = self.meter
        row.onClick = { [weak controller] in
            guard let controller else { return }
            controller.inspectorState.expandedShapes[meter.lowercased()] = key
            controller.rebuildKeepingScroll()
        }
        return row
    }

    /// "+ ▾  −  ↑  ↓".
    private func toolbar() -> NSView {
        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.bezelStyle = .texturedRounded
        add.controlSize = .small
        add.identifier = NSUserInterfaceItemIdentifier("shape-add")
        add.toolTip = "Add a shape"
        let menu = NSMenu()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = EditorStyle.image("plus", size: 11, weight: .semibold)
        menu.addItem(head)
        for kind in [ShapeSpec.Kind.rectangle, .ellipse, .line, .arc, .curve] {
            menu.addItem(ClosureMenuItem(kind.title, symbol: kind.symbol) { [weak controller, meter] in
                controller?.addShape(kind, meter: meter)
            })
        }
        add.menu = menu
        func button(_ symbol: String, _ tip: String, _ id: String, enabled: Bool, _ action: @escaping () -> Void) -> NSButton {
            let b = NSButton(image: EditorStyle.image(symbol, size: 11, weight: .semibold) ?? NSImage(), target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.isEnabled = enabled
            b.onAction { _ in action() }
            return b
        }
        let index = items.firstIndex { $0.key == selectedKey }
        let key = selectedKey ?? "", meter = self.meter
        let remove = button("minus", "Remove the selected shape", "shape-remove", enabled: index != nil) { [weak controller] in
            controller?.removeShape(key, meter: meter)
        }
        let up = button("chevron.up", "Move back (drawn earlier)", "shape-up", enabled: (index ?? 0) > 0) { [weak controller] in
            controller?.moveShape(key, by: -1, meter: meter)
        }
        let down = button("chevron.down", "Move forward (drawn later, in front)", "shape-down",
                          enabled: index.map { $0 < items.count - 1 } ?? false) { [weak controller] in
            controller?.moveShape(key, by: 1, meter: meter)
        }
        return EditorStyle.hstack([add, remove, up, down, EditorStyle.spacer()], spacing: 4)
    }

    /// The expanded shape.
    private func detail(_ item: ShapeItem) -> NSView {
        guard let controller else { return NSView() }
        guard let spec = item.spec else { return unreadable(item) }
        var sections: [NSView] = []
        var rows: [InspectorRow] = []
        if !essentialsAbove { rows.append(InspectorRow(label: label("Type"), control: typePopup(item, spec))) }
        if let origin = controller.inheritedStyle(section: meter, key: item.key) {
            let badge = EditorStyle.originBadge(origin)
            badge.onAction { [weak controller] _ in controller?.select(section: origin) }
            badge.toolTip = "This shape comes from a look (\(origin)) — changes apply to every layer using it. Click to open it."
            rows.append(InspectorRow(label: nil, control: EditorStyle.hstack([badge, EditorStyle.spacer()], spacing: 0)))
        }
        if let problem = spec.problem {
            rows.append(InspectorRow(label: nil, control: EditorStyle.issue(problem, width: controller.inspectorControlWidth)))
        }
        rows += geometryRows(item, spec)
        sections.append(EditorStyle.grid(rows))
        let gradient: Bool = { switch spec.fill { case .linearGradient?, .radialGradient?: return true; default: return false } }()
        if !essentialsAbove || gradient {
            sections.append(subheading("Fill"))
            sections.append(EditorStyle.grid(fillRows(item, spec)))
        }
        let stroke = strokeRows(item, spec)
        if !stroke.isEmpty {
            sections.append(subheading("Outline"))
            sections.append(EditorStyle.grid(stroke))
        }
        sections.append(disclosure("Transform", id: "transform", item: item))
        if controller.inspectorState.disclosures.contains(disclosureID("transform", item)) {
            sections.append(EditorStyle.grid(transformRows(item, spec)))
        }
        let stack = EditorStyle.vstack(sections, spacing: 10)
        for v in sections { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    /// A shape the model cannot read at all (its first part is not even a word).
    private func unreadable(_ item: ShapeItem) -> NSView {
        let message = EditorStyle.label("This part is written in a way the controls can't show", size: 12, weight: .medium)
        message.maximumNumberOfLines = 2
        message.cell?.wraps = true
        message.lineBreakMode = .byWordWrapping
        var views: [NSView] = [message]
        if let problem = ShapeSpec.problem(in: item.row.raw) {
            views.append(EditorStyle.issue(problem, width: (controller?.inspectorControlWidth ?? 180) + EditorStyle.labelColumnWidth))
        }
        let raw = NSTextField(wrappingLabelWithString: item.row.raw)
        raw.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        raw.textColor = .secondaryLabelColor
        raw.maximumNumberOfLines = 4
        views.append(raw)
        let code = NSButton(title: "Show in Code", target: nil, action: nil)
        code.bezelStyle = .rounded
        code.controlSize = .small
        code.identifier = NSUserInterfaceItemIdentifier("shape-show-in-code")
        let location = item.row.location
        code.onAction { [weak controller] _ in controller?.showInCode(location) }
        views.append(code)
        let stack = EditorStyle.vstack(views, spacing: 6)
        stack.identifier = NSUserInterfaceItemIdentifier("shape-unreadable")
        return stack
    }

    private func label(_ text: String, tooltip: String? = nil) -> NSView {
        EditorStyle.rowLabel(text, key: nil, tooltip: tooltip)
    }

    private func subheading(_ text: String) -> NSView {
        let l = EditorStyle.label(text.uppercased(), size: 9.5, weight: .semibold, color: .tertiaryLabelColor)
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor, .kern: 0.7,
        ])
        return l
    }

    private func disclosureID(_ id: String, _ item: ShapeItem) -> String { "\(meter.lowercased())/\(item.key.lowercased())/\(id)" }

    private func disclosure(_ title: String, id: String, item: ShapeItem) -> NSView {
        let key = disclosureID(id, item)
        let open = controller?.inspectorState.disclosures.contains(key) ?? false
        let b = EditorStyle.disclosure(title, open: open)
        b.identifier = NSUserInterfaceItemIdentifier("shape-disclosure-\(id)")
        b.onAction { [weak controller] _ in
            guard let controller else { return }
            if controller.inspectorState.disclosures.contains(key) {
                controller.inspectorState.disclosures.remove(key)
            } else {
                controller.inspectorState.disclosures.insert(key)
            }
            controller.rebuildKeepingScroll()
        }
        return EditorStyle.hstack([b, EditorStyle.spacer()], spacing: 0)
    }

    // MARK: Type and geometry

    /// The type menu. A type word that is not a type (`aaaa`) is shown as it is written — first, selected, disabled —
    /// above the valid types (docs/editor-design.md §3: invalid values are never replaced silently); choosing one
    /// replaces only the word.
    private func typePopup(_ item: ShapeItem, _ spec: ShapeSpec) -> NSView {
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("shape-type")
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.autoenablesItems = false
        if let unknown = spec.unknownType {
            popup.addItem(withTitle: "“\(unknown)”")
            popup.lastItem?.image = EditorStyle.image("exclamationmark.triangle", size: 12)
            popup.lastItem?.isEnabled = false
            popup.menu?.addItem(.separator())
        }
        for kind in ShapeSpec.Kind.allCases {
            popup.addItem(withTitle: kind.title)
            popup.lastItem?.representedObject = kind.rawValue
            popup.lastItem?.image = EditorStyle.image(kind.symbol, size: 12)
        }
        if spec.unknownType != nil {
            popup.selectItem(at: 0)
        } else if let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == spec.kind.rawValue }) {
            popup.selectItem(at: i)
        }
        let key = item.key, meter = self.meter
        popup.onAction { [weak controller] c in
            guard let raw = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String,
                  let kind = ShapeSpec.Kind(rawValue: raw) else { return }
            controller?.setShapeKind(kind, key: key, meter: meter)
        }
        return popup
    }

    /// A parameter of the geometry: its text as written, read and written through the typed geometry.
    struct Param {
        var caption: String
        var get: (ShapeSpec) -> String?
        var set: (inout ShapeSpec, String?) -> Void
        var placeholder: String
    }

    private func geometryRows(_ item: ShapeItem, _ spec: ShapeSpec) -> [InspectorRow] {
        typealias P = Param
        func req(_ v: String?) -> String { (v ?? "").isEmpty ? "0" : v! }
        if spec.unknownType != nil {
            // No type, so no geometry to name: the parameters as written, kept until a type is chosen.
            let field = ValueField(spec.params.joined(separator: ","), placeholder: "none")
            field.identifier = controlID(item, "Parameters")
            field.toolTip = "The parameters as written; choose a type to edit them one by one"
            let key = item.key, meter = self.meter
            field.onCommit = { [weak controller] v in
                let params = v.isEmpty ? [] : v.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                controller?.editShape(key, meter: meter) { s in s.params = params }
            }
            return [InspectorRow(label: label("Parameters"), control: field)]
        }
        switch spec.kind {
        case .rectangle:
            let x = P(caption: "X", get: { $0.rectangle?.x }, set: { s, v in if var g = s.rectangle { g.x = req(v); s.rectangle = g } }, placeholder: "0")
            let y = P(caption: "Y", get: { $0.rectangle?.y }, set: { s, v in if var g = s.rectangle { g.y = req(v); s.rectangle = g } }, placeholder: "0")
            let w = P(caption: "W", get: { $0.rectangle?.width }, set: { s, v in if var g = s.rectangle { g.width = req(v); s.rectangle = g } }, placeholder: "0")
            let h = P(caption: "H", get: { $0.rectangle?.height }, set: { s, v in if var g = s.rectangle { g.height = req(v); s.rectangle = g } }, placeholder: "0")
            let rx = P(caption: "R", get: { $0.rectangle?.radiusX }, set: { s, v in if var g = s.rectangle { g.radiusX = v; s.rectangle = g } }, placeholder: "0")
            let ry = P(caption: "Y", get: { $0.rectangle?.radiusY }, set: { s, v in if var g = s.rectangle { g.radiusY = v; s.rectangle = g } }, placeholder: "same")
            return [pairRow("Position", item, x, y), pairRow("Size", item, w, h),
                    radiusRow("Corners", item, rx, ry, linked: spec.rectangle?.radiusY == nil)]
        case .ellipse:
            let x = P(caption: "X", get: { $0.ellipse?.centerX }, set: { s, v in if var g = s.ellipse { g.centerX = req(v); s.ellipse = g } }, placeholder: "0")
            let y = P(caption: "Y", get: { $0.ellipse?.centerY }, set: { s, v in if var g = s.ellipse { g.centerY = req(v); s.ellipse = g } }, placeholder: "0")
            let rx = P(caption: "R", get: { $0.ellipse?.radiusX }, set: { s, v in if var g = s.ellipse { g.radiusX = req(v); s.ellipse = g } }, placeholder: "0")
            let ry = P(caption: "Y", get: { $0.ellipse?.radiusY }, set: { s, v in if var g = s.ellipse { g.radiusY = v; s.ellipse = g } }, placeholder: "same")
            return [pairRow("Center", item, x, y), radiusRow("Radius", item, rx, ry, linked: spec.ellipse?.radiusY == nil)]
        case .line:
            return [pairRow("Start", item,
                            P(caption: "X", get: { $0.line?.startX }, set: { s, v in if var g = s.line { g.startX = req(v); s.line = g } }, placeholder: "0"),
                            P(caption: "Y", get: { $0.line?.startY }, set: { s, v in if var g = s.line { g.startY = req(v); s.line = g } }, placeholder: "0")),
                    pairRow("End", item,
                            P(caption: "X", get: { $0.line?.endX }, set: { s, v in if var g = s.line { g.endX = req(v); s.line = g } }, placeholder: "0"),
                            P(caption: "Y", get: { $0.line?.endY }, set: { s, v in if var g = s.line { g.endY = req(v); s.line = g } }, placeholder: "0"))]
        case .arc:
            let g = spec.arc
            var rows = [
                pairRow("Start", item,
                        P(caption: "X", get: { $0.arc?.startX }, set: { s, v in if var g = s.arc { g.startX = req(v); s.arc = g } }, placeholder: "0"),
                        P(caption: "Y", get: { $0.arc?.startY }, set: { s, v in if var g = s.arc { g.startY = req(v); s.arc = g } }, placeholder: "0")),
                pairRow("End", item,
                        P(caption: "X", get: { $0.arc?.endX }, set: { s, v in if var g = s.arc { g.endX = req(v); s.arc = g } }, placeholder: "0"),
                        P(caption: "Y", get: { $0.arc?.endY }, set: { s, v in if var g = s.arc { g.endY = req(v); s.arc = g } }, placeholder: "0")),
                radiusRow("Radius", item,
                          P(caption: "R", get: { $0.arc?.radiusX }, set: { s, v in if var g = s.arc { g.radiusX = v; s.arc = g } },
                            placeholder: g?.defaultRadius.map { GeometryEdit.format($0) } ?? "auto"),
                          P(caption: "Y", get: { $0.arc?.radiusY }, set: { s, v in if var g = s.arc { g.radiusY = v; s.arc = g } }, placeholder: "same"),
                          linked: g?.radiusY == nil),
                InspectorRow(label: label("Rotation"), control: angleControl(item, "Rotation", value: g?.rotation, orientation: true) { s, v in
                    if var g = s.arc { g.rotation = v; s.arc = g }
                }),
            ]
            rows.append(InspectorRow(label: label("Direction"), control: segmented(
                "shape-arc-direction", ["Clockwise", "Counter-clockwise"], selected: g?.isCounterClockwise == true ? 1 : 0, item: item) { s, i in
                    if var g = s.arc { g.isCounterClockwise = i == 1; s.arc = g }
                }))
            rows.append(InspectorRow(label: label("Size"), control: segmented(
                "shape-arc-size", ["Small arc", "Large arc"], selected: g?.isLarge == true ? 1 : 0, item: item) { s, i in
                    if var g = s.arc { g.isLarge = i == 1; s.arc = g }
                }))
            rows.append(InspectorRow(label: nil, control: checkbox("Closed", id: "shape-closed", on: g?.isClosed == true, item: item) { s, on in
                if var g = s.arc { g.isClosed = on; s.arc = g }
            }))
            return rows
        case .curve:
            let g = spec.curve
            return [
                pairRow("Start", item,
                        P(caption: "X", get: { $0.curve?.startX }, set: { s, v in if var g = s.curve { g.startX = req(v); s.curve = g } }, placeholder: "0"),
                        P(caption: "Y", get: { $0.curve?.startY }, set: { s, v in if var g = s.curve { g.startY = req(v); s.curve = g } }, placeholder: "0")),
                pairRow("Control", item,
                        P(caption: "X", get: { $0.curve?.controlX1 }, set: { s, v in if var g = s.curve { g.controlX1 = req(v); s.curve = g } }, placeholder: "0"),
                        P(caption: "Y", get: { $0.curve?.controlY1 }, set: { s, v in if var g = s.curve { g.controlY1 = req(v); s.curve = g } }, placeholder: "0")),
                pairRow("Control 2", item,
                        P(caption: "X", get: { $0.curve?.controlX2 }, set: { s, v in if var g = s.curve { g.controlX2 = v; if v == nil { g.controlY2 = nil }; s.curve = g } }, placeholder: "none"),
                        P(caption: "Y", get: { $0.curve?.controlY2 }, set: { s, v in if var g = s.curve { g.controlY2 = v; if v == nil { g.controlX2 = nil }; s.curve = g } }, placeholder: "none")),
                pairRow("End", item,
                        P(caption: "X", get: { $0.curve?.endX }, set: { s, v in if var g = s.curve { g.endX = req(v); s.curve = g } }, placeholder: "0"),
                        P(caption: "Y", get: { $0.curve?.endY }, set: { s, v in if var g = s.curve { g.endY = req(v); s.curve = g } }, placeholder: "0")),
                InspectorRow(label: nil, control: checkbox("Closed", id: "shape-closed", on: g?.isClosed == true, item: item) { s, on in
                    if var g = s.curve { g.isClosed = on; s.curve = g }
                }),
            ]
        case .path, .path1:
            return [InspectorRow(label: label("Path", tooltip: "The option of this layer that defines the path"),
                                 control: optionPopup(item, current: spec.pathOption) { s, v in s.pathOption = v })]
        case .combine:
            return combineRows(item, spec)
        }
    }

    /// Two parameters side by side (X Y, W H).
    private func pairRow(_ title: String, _ item: ShapeItem, _ a: Param, _ b: Param) -> InspectorRow {
        InspectorRow(label: label(title), control: EditorStyle.pair(paramCell(item, a, row: title), paramCell(item, b, row: title)))
    }

    /// A radius with a link toggle: linked, one field (Y follows X); unlinked, X and Y.
    private func radiusRow(_ title: String, _ item: ShapeItem, _ x: Param, _ y: Param, linked: Bool) -> InspectorRow {
        let link = NSButton()
        link.setButtonType(.pushOnPushOff)
        link.isBordered = false
        link.image = EditorStyle.image("link", size: 11, weight: .medium)
        link.state = linked ? .on : .off
        link.contentTintColor = linked ? .controlAccentColor : .tertiaryLabelColor
        link.toolTip = linked ? "Horizontal and vertical radius are the same — click to set them apart" : "Use one radius"
        link.identifier = NSUserInterfaceItemIdentifier("shape-radius-link")
        let key = item.key, meter = self.meter
        link.onAction { [weak controller] b in
            let on = (b as? NSButton)?.state == .on
            controller?.editShape(key, meter: meter) { spec in
                if on { y.set(&spec, nil) } else { y.set(&spec, x.get(spec) ?? "0") }
            }
        }
        let first = paramCell(item, x, row: title)
        let control: NSView
        if linked {
            first.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control = EditorStyle.hstack([first, link], spacing: 4)
        } else {
            let pair = EditorStyle.pair(first, paramCell(item, y, row: title))
            control = EditorStyle.hstack([pair, link], spacing: 4)
        }
        return InspectorRow(label: label(title), control: control)
    }

    /// The identifier of a control of the expanded shape: unique in the inspector ("Shapes/Shape2/End/X"), so the
    /// focus comes back to the same field after the rebuild that follows every write.
    private func controlID(_ item: ShapeItem, _ parts: String...) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(([meter, item.key] + parts).joined(separator: "/"))
    }

    /// One parameter: a number field, or a pill when it is a formula or a variable (kept as written). `row` is the
    /// title of its row (Start, End, Control 2…): captions repeat between rows.
    private func paramCell(_ item: ShapeItem, _ p: Param, row: String) -> NSView {
        guard let spec = item.spec, let controller else { return NSView() }
        let written = p.get(spec) ?? ""
        let caption = EditorStyle.caption(p.caption)
        let key = item.key, meter = self.meter
        let control: NSView
        if LenientNumberFormatter.isExpression(written) {
            let number = item.resolved.flatMap { p.get($0) }.flatMap(OptionValue.number)
            let variable = controller.wholeVariable(written)
            let pill = PillView(name: variable, value: number.map { EditorStyle.number($0) } ?? "?",
                                symbol: variable == nil ? "function" : nil)
            pill.toolTip = written
            let slot = EditorStyle.hstack([pill, EditorStyle.spacer()], spacing: 0)
            let location = item.row.location
            pill.menuProvider = { [weak controller, weak slot, weak pill] in
                guard let controller, let slot, let pill else { return NSMenu() }
                return controller.pillMenu(variable: nil, detach: number.map { GeometryEdit.format($0) }, location: location, edit: {
                    controller.editPillInline(slot: slot, pill: pill, variable: nil, raw: written) { v in
                        controller.editShape(key, meter: meter) { s in p.set(&s, v.isEmpty ? nil : v) }
                    }
                }, detachAction: {
                    guard let number else { return }
                    controller.editShape(key, meter: meter) { s in p.set(&s, GeometryEdit.format(number)) }
                })
            }
            control = slot
        } else {
            let field = NumberField(written, placeholder: p.placeholder, min: nil, max: nil)
            field.identifier = controlID(item, row, p.caption)
            field.onCommit = { [weak controller] v in
                controller?.editShape(key, meter: meter) { s in p.set(&s, v.isEmpty ? nil : v) }
            }
            control = field
        }
        return EditorStyle.hstack([caption, control], spacing: 5)
    }

    private func segmented(_ id: String, _ titles: [String], selected: Int, item: ShapeItem,
                           _ apply: @escaping (inout ShapeSpec, Int) -> Void) -> NSView {
        let seg = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        seg.controlSize = .small
        seg.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        seg.selectedSegment = selected
        seg.identifier = NSUserInterfaceItemIdentifier(id)
        let key = item.key, meter = self.meter
        seg.onAction { [weak controller] c in
            guard let index = (c as? NSSegmentedControl)?.selectedSegment else { return }
            controller?.editShape(key, meter: meter) { s in apply(&s, index) }
        }
        return EditorStyle.hstack([seg, EditorStyle.spacer()], spacing: 0)
    }

    private func checkbox(_ title: String, id: String, on: Bool, item: ShapeItem,
                          _ apply: @escaping (inout ShapeSpec, Bool) -> Void) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        box.identifier = NSUserInterfaceItemIdentifier(id)
        let key = item.key, meter = self.meter
        box.onAction { [weak controller] c in
            let on = (c as? NSButton)?.state == .on
            controller?.editShape(key, meter: meter) { s in apply(&s, on) }
        }
        return box
    }

    /// An angle in degrees (dial + field) written into the shape; the dial previews and writes on release.
    private func angleControl(_ item: ShapeItem, _ title: String, value: String?, orientation: Bool,
                              _ apply: @escaping (inout ShapeSpec, String?) -> Void) -> NSView {
        let written = value ?? ""
        if LenientNumberFormatter.isExpression(written) {
            let pill = PillView(name: controller?.wholeVariable(written), value: written, symbol: "function")
            pill.toolTip = written
            return EditorStyle.hstack([pill, EditorStyle.spacer()], spacing: 0)
        }
        let control = AngleControl(raw: written, unit: .degrees, orientation: orientation, placeholder: "0")
        control.identifier = controlID(item, title)
        control.field.identifier = controlID(item, title, "degrees")
        control.dial?.identifier = controlID(item, title, "dial")
        let key = item.key, meter = self.meter
        control.onChange = { [weak controller] v, finished in
            controller?.previewShapeEdit(key, meter: meter, finished: finished) { s in apply(&s, v.isEmpty || v == "0" ? nil : v) }
        }
        return control
    }

    /// A pop-up of the meter's other options (the path definition of a Path shape).
    private func optionPopup(_ item: ShapeItem, current: String?, _ apply: @escaping (inout ShapeSpec, String?) -> Void) -> NSView {
        guard let controller else { return NSView() }
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("shape-path-option")
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let skip = Set(["meter", "meterstyle", "x", "y", "w", "h", "dynamicvariables", "updatedivider", "hidden", "antialias"])
        let options = controller.shapeRows(of: meter).map(\.key).filter { k in
            ShapeSpec.index(ofOption: k) == nil && !skip.contains(k.lowercased()) && EditorSchema.property(k, in: EditorSchema.meterGroups("shape")) == nil
        }
        popup.addItem(withTitle: "Choose an option…")
        popup.lastItem?.representedObject = ""
        for o in options {
            popup.addItem(withTitle: o)
            popup.lastItem?.representedObject = o
        }
        if let current, !options.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            popup.addItem(withTitle: "\(current) (missing)")
            popup.lastItem?.representedObject = current
        }
        if let current, let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(current) == .orderedSame }) {
            popup.selectItem(at: i)
        }
        let key = item.key, meter = self.meter
        popup.onAction { [weak controller] c in
            guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            controller?.editShape(key, meter: meter) { s in apply(&s, v.isEmpty ? nil : v) }
        }
        return popup
    }

    /// Combine: the parent shape and the steps (operation + shape), with + / −.
    private func combineRows(_ item: ShapeItem, _ spec: ShapeSpec) -> [InspectorRow] {
        let others = items.filter { $0.key != item.key }.map(\.key)
        let key = item.key, meter = self.meter
        func shapePopup(_ current: String?, id: String, _ apply: @escaping (inout ShapeSpec, String) -> Void) -> NSPopUpButton {
            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier(id)
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            if current == nil { popup.addItem(withTitle: "Choose a shape…"); popup.lastItem?.representedObject = "" }
            for o in others {
                let summary = items.first { $0.key == o }.map(Self.summary) ?? o
                popup.addItem(withTitle: "\(o) — \(summary)")
                popup.lastItem?.representedObject = o
            }
            if let current, !others.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
                popup.addItem(withTitle: "\(current) (missing)")
                popup.lastItem?.representedObject = current
            }
            if let current, let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(current) == .orderedSame }) {
                popup.selectItem(at: i)
            }
            popup.onAction { [weak controller] c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, !v.isEmpty else { return }
                controller?.editShape(key, meter: meter) { s in apply(&s, v) }
            }
            return popup
        }
        var rows = [InspectorRow(label: label("Parent"), control: shapePopup(spec.combineParent, id: "shape-combine-parent") { s, v in
            s.combineParent = v
        })]
        let operations: [ShapeCombineMode] = [.union, .intersect, .xor, .exclude]
        let titles: [ShapeCombineMode: String] = [.union: "Add (union)", .intersect: "Keep the overlap", .xor: "Keep the rest (XOR)",
                                                  .exclude: "Cut out"]
        for (i, step) in spec.combineSteps.enumerated() {
            let op = NSPopUpButton()
            op.identifier = NSUserInterfaceItemIdentifier("shape-combine-op-\(i)")
            for o in operations {
                op.addItem(withTitle: titles[o] ?? o.keyword)
                op.lastItem?.representedObject = o.rawValue
            }
            op.selectItem(at: operations.firstIndex(of: step.operation) ?? 0)
            op.onAction { [weak controller] c in
                guard let raw = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String,
                      let mode = ShapeCombineMode(rawValue: raw) else { return }
                controller?.editShape(key, meter: meter) { s in
                    var steps = s.combineSteps
                    if i < steps.count { steps[i].operation = mode }
                    s.combineSteps = steps
                }
            }
            let target = shapePopup(step.shape, id: "shape-combine-shape-\(i)") { s, v in
                var steps = s.combineSteps
                if i < steps.count { steps[i].shape = v }
                s.combineSteps = steps
            }
            let remove = NSButton(image: EditorStyle.image("minus.circle", size: 12) ?? NSImage(), target: nil, action: nil)
            remove.isBordered = false
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = "Remove this step"
            remove.onAction { [weak controller] _ in
                // Renumbers the steps: a value typed for another step is written first.
                controller?.editShape(key, meter: meter) { s in
                    var steps = s.combineSteps
                    if i < steps.count { steps.remove(at: i) }
                    s.combineSteps = steps
                }
            }
            let line = EditorStyle.vstack([op, EditorStyle.hstack([target, remove], spacing: 4)], spacing: 4)
            op.widthAnchor.constraint(equalTo: line.widthAnchor).isActive = true
            rows.append(InspectorRow(label: label(i == 0 ? "Steps" : ""), control: line))
        }
        let add = NSButton(title: "Add Step", target: nil, action: nil)
        add.image = EditorStyle.image("plus", size: 10, weight: .semibold)
        add.imagePosition = .imageLeading
        add.bezelStyle = .inline
        add.controlSize = .small
        add.identifier = NSUserInterfaceItemIdentifier("shape-combine-add")
        add.isEnabled = !others.isEmpty
        let firstOther = others.first { $0.caseInsensitiveCompare(spec.combineParent ?? "") != .orderedSame } ?? others.first
        add.onAction { [weak controller] _ in
            guard let firstOther else { return }
            controller?.editShape(key, meter: meter) { s in
                s.combineSteps = s.combineSteps + [ShapeSpec.CombineStep(.union, firstOther)]
            }
        }
        rows.append(InspectorRow(label: nil, control: EditorStyle.hstack([add, EditorStyle.spacer()], spacing: 0)))
        return rows
    }

    // MARK: Fill

    enum FillMode: Int { case none, color, linear, radial }

    static func fillMode(_ spec: ShapeSpec) -> FillMode {
        switch spec.fill {
        case .color(let c)?:
            return OptionValue.color(c).map { $0.a == 0 } == true ? .none : .color
        case .linearGradient?: return .linear
        case .radialGradient?: return .radial
        case nil: return spec.isClosed == false ? .none : .color
        }
    }

    private func fillRows(_ item: ShapeItem, _ spec: ShapeSpec) -> [InspectorRow] {
        guard let controller else { return [] }
        let mode = Self.fillMode(spec)
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("shape-fill")
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for (title, symbol) in [("None", "circle.slash"), ("Color", "circle.fill"), ("Linear gradient", "square.bottomhalf.filled"),
                                ("Radial gradient", "circle.dashed.inset.filled")] {
            popup.addItem(withTitle: title)
            popup.lastItem?.image = EditorStyle.image(symbol, size: 12)
        }
        popup.selectItem(at: mode.rawValue)
        let key = item.key, meter = self.meter
        popup.onAction { [weak controller] c in
            guard let i = (c as? NSPopUpButton)?.indexOfSelectedItem, let mode = FillMode(rawValue: i) else { return }
            controller?.setShapeFillMode(mode, key: key, meter: meter)
        }
        var rows = [InspectorRow(label: label("Fill"), control: popup)]
        switch mode {
        case .none:
            break
        case .color:
            let written: String? = { if case .color(let c)? = spec.fill { return c } else { return nil } }()
            let resolved: String? = { if case .color(let c)? = item.resolved?.fill { return c } else { return nil } }()
            rows.append(InspectorRow(label: label("Color"), control: colorControl(
                id: "shape-fill-color", written: written, resolved: resolved ?? "255,255,255,255", item: item) { s, text in
                    s.setFill(.color(text))
                }))
        case .linear, .radial:
            rows += gradientRows(item, spec, paint: spec.fill, radial: mode == .radial)
        }
        return rows
    }

    /// A color in the shape: swatch (color panel, live preview) and, for a variable, its pill.
    private func colorControl(id: String, written: String?, resolved: String, item: ShapeItem,
                              _ apply: @escaping (inout ShapeSpec, String) -> Void) -> NSView {
        let swatch = SwatchButton()
        swatch.color = OptionValue.color(resolved)
        swatch.identifier = NSUserInterfaceItemIdentifier(id)
        let variable = written.flatMap { controller?.wholeVariable($0) }
        let key = item.key, meter = self.meter
        swatch.toolTip = variable.map { "Changes the shared color “\($0)” for the whole widget" } ?? "Pick a color"
        swatch.target = ShapeColorPicker.shared
        swatch.action = #selector(ShapeColorPicker.swatchClicked(_:))
        ShapeColorPicker.shared.register(swatch, identity: "\(meter)/\(key)/\(id)", controller: controller) { [weak controller] rgba, finished in
            guard let controller else { return }
            if let variable {
                let like = controller.skin?.inspectedVariables().first { $0.name.caseInsensitiveCompare(variable) == .orderedSame }?.raw
                controller.previewProperty(InspectorWindowController.PreviewTarget(section: meter, key: key, variable: variable,
                                                                                   name: "Color"),
                                           value: ColorText.format(rgba, like: like), finished: finished)
            } else {
                controller.previewShapeEdit(key, meter: meter, finished: finished) { s in
                    apply(&s, ColorText.format(rgba, like: written ?? resolved))
                }
            }
        }
        var parts: [NSView] = [swatch]
        if let variable {
            let pill = PillView(name: variable, value: "", symbol: nil)
            pill.toolTip = "#\(variable)# = \(resolved)"
            let location = controller?.skin?.sources.location(section: "Variables", key: variable)
            pill.menuProvider = { [weak controller] in
                let menu = NSMenu()
                menu.addItem(ClosureMenuItem("Show in Code", symbol: "curlybraces") { controller?.showInCode(location) })
                return menu
            }
            parts.append(pill)
        } else if controller?.showsDetails == true {
            parts.append(EditorStyle.mono(written ?? "\(resolved) (default)", size: 11, color: .secondaryLabelColor))
        } else {
            // In words: "Black (default)", never "0,0,0,255".
            let name = OptionValue.color(resolved).map(LayerNaming.colorName) ?? "Custom"
            let words = name.prefix(1).uppercased() + name.dropFirst() + (written == nil ? " (default)" : "")
            parts.append(EditorStyle.label(words, size: 11.5, color: .secondaryLabelColor))
        }
        parts.append(EditorStyle.spacer())
        return EditorStyle.hstack(parts, spacing: 8)
    }

    /// A gradient: its angle (linear) or center and radii (radial), and its color stops.
    private func gradientRows(_ item: ShapeItem, _ spec: ShapeSpec, paint: ShapeSpec.Paint?, radial: Bool) -> [InspectorRow] {
        guard let controller, let name = paint?.gradientOption else { return [] }
        let meter = self.meter
        let row = controller.shapeRows(of: meter).first { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        guard let raw = row?.raw, let gradient = GradientSpec.parse(raw) else {
            return [InspectorRow(label: nil, control: EditorStyle.issue("The gradient option “\(name)” is missing — nothing is filled",
                                                                          width: controller.inspectorControlWidth))]
        }
        let resolved = row.flatMap { GradientSpec.parse($0.resolved) }
        var rows: [InspectorRow] = []
        if radial {
            func cell(_ caption: String, _ i: Int) -> NSView {
                let field = NumberField(gradient.radial(i) ?? "", placeholder: i < 2 ? "0" : "auto", min: nil, max: nil)
                field.identifier = NSUserInterfaceItemIdentifier("gradient-\(i)")
                field.onCommit = { [weak controller] v in
                    controller?.editGradient(name, meter: meter) { g in g.setRadial(i, v.isEmpty ? nil : v); return true }
                }
                return EditorStyle.hstack([EditorStyle.caption(caption), field], spacing: 5)
            }
            rows.append(InspectorRow(label: label("Center", tooltip: "Offset from the center of the shape"),
                                     control: EditorStyle.pair(cell("X", 0), cell("Y", 1))))
            rows.append(InspectorRow(label: label("Radius"), control: EditorStyle.pair(cell("X", 4), cell("Y", 5))))
        } else {
            let angle = gradient.angle ?? "0"
            if LenientNumberFormatter.isExpression(angle) {
                rows.append(InspectorRow(label: label("Angle"), control: PillView(name: nil, value: angle, symbol: "function")))
            } else {
                let control = AngleControl(raw: angle, unit: .degrees, orientation: true, placeholder: "0")
                control.identifier = NSUserInterfaceItemIdentifier("gradient-angle")
                control.field.identifier = controlID(item, "gradient", "angle")
                control.dial?.identifier = controlID(item, "gradient", "dial")
                control.onChange = { [weak controller] v, finished in
                    controller?.previewGradientEdit(name, meter: meter, finished: finished) { g in g.angle = v.isEmpty ? "0" : v }
                }
                rows.append(InspectorRow(label: label("Angle", tooltip: "0 runs right to left, 90 bottom to top"), control: control))
            }
        }
        for (i, stop) in gradient.stops.enumerated() {
            let resolvedColor = resolved.flatMap { i < $0.stops.count ? $0.stops[i].color : nil } ?? stop.color
            let swatch = SwatchButton()
            swatch.color = OptionValue.color(resolvedColor)
            swatch.identifier = NSUserInterfaceItemIdentifier("gradient-stop-\(i)")
            swatch.target = ShapeColorPicker.shared
            swatch.action = #selector(ShapeColorPicker.swatchClicked(_:))
            let variable = controller.wholeVariable(stop.color)
            swatch.toolTip = variable.map { "Changes the shared color “\($0)” for the whole widget" } ?? stop.color
            ShapeColorPicker.shared.register(swatch, identity: "\(meter)/\(name)/stop-\(i)", controller: controller) { [weak controller] rgba, finished in
                guard let controller else { return }
                if let variable {
                    let like = controller.skin?.inspectedVariables().first { $0.name.caseInsensitiveCompare(variable) == .orderedSame }?.raw
                    controller.previewProperty(InspectorWindowController.PreviewTarget(section: meter, key: name, variable: variable,
                                                                                       name: "Color"),
                                               value: ColorText.format(rgba, like: like), finished: finished)
                } else {
                    controller.previewGradientEdit(name, meter: meter, finished: finished) { g in
                        if i < g.stops.count { g.stops[i].color = ColorText.format(rgba, like: stop.color) }
                    }
                }
            }
            let position = NumberField(stop.position ?? "", placeholder: "auto", min: 0, max: 1)
            position.identifier = NSUserInterfaceItemIdentifier("gradient-position-\(i)")
            position.toolTip = "Position, 0 to 1"
            position.widthAnchor.constraint(equalToConstant: 44).isActive = true
            position.onCommit = { [weak controller] v in
                controller?.editGradient(name, meter: meter) { g in
                    guard i < g.stops.count else { return false }
                    g.stops[i].position = v.isEmpty ? nil : v
                    return true
                }
            }
            let colorText = variable ?? stop.color
            let text = EditorStyle.label(colorText, size: 11, color: variable != nil ? .systemPurple : .secondaryLabelColor)
            text.toolTip = variable.map { "#\($0)#" } ?? stop.color
            let remove = NSButton(image: EditorStyle.image("minus.circle", size: 12) ?? NSImage(), target: nil, action: nil)
            remove.isBordered = false
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = "Remove this color"
            remove.identifier = NSUserInterfaceItemIdentifier("gradient-remove-\(i)")
            remove.isEnabled = gradient.stops.count > 2
            remove.onAction { [weak controller] _ in
                // Renumbers the colors: a position typed for another one is written first.
                controller?.editGradient(name, meter: meter) { g in
                    guard i < g.stops.count, g.stops.count > 2 else { return false }
                    g.stops.remove(at: i)
                    return true
                }
            }
            let line = EditorStyle.hstack([swatch, position, text, EditorStyle.spacer(), remove], spacing: 6)
            rows.append(InspectorRow(label: label(i == 0 ? "Colors" : ""), control: line))
        }
        let add = NSButton(title: "Add Color", target: nil, action: nil)
        add.image = EditorStyle.image("plus", size: 10, weight: .semibold)
        add.imagePosition = .imageLeading
        add.bezelStyle = .inline
        add.controlSize = .small
        add.identifier = NSUserInterfaceItemIdentifier("gradient-add")
        add.onAction { [weak controller] _ in
            controller?.editGradient(name, meter: meter) { g in
                let last = g.stops.last?.color ?? "255,255,255,255"
                g.stops.append(GradientSpec.Stop(color: last, position: "1.0"))
                return true
            }
        }
        let code = NSButton(title: name, target: nil, action: nil)
        code.isBordered = false
        code.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        code.contentTintColor = .controlAccentColor
        code.image = EditorStyle.image("arrow.up.forward", size: 8, weight: .semibold)
        code.imagePosition = .imageTrailing
        code.toolTip = "The gradient is the option \(name) of this layer — show it in the code"
        code.identifier = NSUserInterfaceItemIdentifier("gradient-code")
        code.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let location = row?.location
        code.onAction { [weak controller] _ in controller?.showInCode(location) }
        rows.append(InspectorRow(label: nil, control: EditorStyle.hstack([add, EditorStyle.spacer(), code], spacing: 6)))
        return rows
    }

    // MARK: Stroke

    static let dashes: [(title: String, values: [String]?)] = [("Solid", nil), ("Dashed", ["4", "2"]), ("Dotted", ["1", "1"])]
    static let caps: [(String, ShapeLineCap)] = [("Flat", .flat), ("Round", .round), ("Square", .square), ("Triangle", .triangle)]
    static let joins: [(String, ShapeLineJoin)] = [("Miter", .miter), ("Bevel", .bevel), ("Round", .round),
                                                   ("Miter or bevel", .miterOrBevel)]

    private func strokeRows(_ item: ShapeItem, _ spec: ShapeSpec) -> [InspectorRow] {
        guard let controller else { return [] }
        let width = spec.strokeWidth
        let resolvedWidth = item.resolved?.strokeWidth.flatMap(OptionValue.number) ?? OptionValue.number(width ?? "1") ?? 1
        let on = resolvedWidth != 0
        let key = item.key, meter = self.meter
        let box = NSButton(checkboxWithTitle: "Outline", target: nil, action: nil)
        box.state = on ? .on : .off
        box.identifier = NSUserInterfaceItemIdentifier("shape-stroke")
        box.toolTip = "Off: no outline"
        box.onAction { [weak controller] c in controller?.setShapeStroke((c as? NSButton)?.state == .on, key: key, meter: meter) }
        var rows = [InspectorRow(label: nil, control: box)]
        guard on else { return essentialsAbove ? [] : rows }
        if essentialsAbove {
            // The card above has the outline, its color, thickness and dashes: here only the line's ends and corners.
            rows = [InspectorRow(label: nil, control: disclosure("Caps and join", id: "caps", item: item))]
            if controller.inspectorState.disclosures.contains(disclosureID("caps", item)) { rows += capRows(item, spec) }
            return rows
        }
        let written: String? = { if case .color(let c)? = spec.stroke { return c } else { return nil } }()
        let resolved: String? = { if case .color(let c)? = item.resolved?.stroke { return c } else { return nil } }()
        rows.append(InspectorRow(label: label("Color"), control: colorControl(
            id: "shape-stroke-color", written: written, resolved: resolved ?? "0,0,0,255", item: item) { s, text in
                s.setStroke(.color(text))
            }))
        if let width, LenientNumberFormatter.isExpression(width) {
            rows.append(InspectorRow(label: label("Thickness"), control: EditorStyle.hstack([
                PillView(name: controller.wholeVariable(width), value: "= " + EditorStyle.number(resolvedWidth), symbol: "function"),
                EditorStyle.spacer()], spacing: 0)))
        } else {
            let control = NumberControl(value: width ?? "", placeholder: "1", min: 0, max: 1000, step: 0.5, unit: "px", fallback: 1)
            control.identifier = NSUserInterfaceItemIdentifier("shape-stroke-width")
            control.field.identifier = controlID(item, "Stroke", "Width")
            control.onCommit = { [weak controller] v in
                controller?.editShape(key, meter: meter) { s in s.setStrokeWidth(v.isEmpty ? nil : v) }
            }
            control.onStep = { [weak controller] v, finished in
                controller?.previewShapeEdit(key, meter: meter, finished: finished) { s in s.setStrokeWidth(v) }
            }
            rows.append(InspectorRow(label: label("Thickness"), control: control))
        }
        // Dashes: Solid | Dashed | Dotted | Custom (the list as written).
        let current: [String]? = { if case .strokeDashes(let d)? = spec.modifier(.strokeDashes), !d.isEmpty { return d } else { return nil } }()
        let preset = Self.dashes.firstIndex { $0.values == current }
        let dash = NSPopUpButton()
        dash.identifier = NSUserInterfaceItemIdentifier("shape-dash")
        for d in Self.dashes { dash.addItem(withTitle: d.title) }
        dash.addItem(withTitle: "Custom")
        dash.selectItem(at: preset ?? Self.dashes.count)
        dash.onAction { [weak controller] c in
            guard let i = (c as? NSPopUpButton)?.indexOfSelectedItem else { return }
            if i >= Self.dashes.count, current != nil, preset == nil { return }
            controller?.editShape(key, meter: meter) { s in
                s.setStrokeDashes(i < Self.dashes.count ? Self.dashes[i].values : ["3", "1", "1", "1"])
            }
        }
        var dashControl: NSView = dash
        if preset == nil {
            let field = ValueField(current?.joined(separator: ",") ?? "", placeholder: "dash, gap, …")
            field.identifier = NSUserInterfaceItemIdentifier("shape-dash-custom")
            field.toolTip = "Dash and gap lengths in stroke widths"
            field.onCommit = { [weak controller] v in
                let items = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                controller?.editShape(key, meter: meter) { s in s.setStrokeDashes(items.isEmpty ? nil : items) }
            }
            dashControl = EditorStyle.vstack([dash, field], spacing: 4)
            field.widthAnchor.constraint(equalTo: dashControl.widthAnchor).isActive = true
        }
        rows.append(InspectorRow(label: label("Dashes"), control: dashControl))
        rows.append(InspectorRow(label: nil, control: disclosure("Caps and join", id: "caps", item: item)))
        if controller.inspectorState.disclosures.contains(disclosureID("caps", item)) { rows += capRows(item, spec) }
        return rows
    }

    /// Start, end and dash caps, and the join.
    private func capRows(_ item: ShapeItem, _ spec: ShapeSpec) -> [InspectorRow] {
        let key = item.key, meter = self.meter
        var rows: [InspectorRow] = []
        func capPopup(_ id: String, _ slot: ShapeSpec.Slot, default d: ShapeLineCap,
                      _ apply: @escaping (inout ShapeSpec, ShapeLineCap?) -> Void) -> NSPopUpButton {
            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier(id)
            var currentCap: ShapeLineCap?
            switch spec.modifier(slot) {
            case .strokeStartCap(let c)?, .strokeEndCap(let c)?, .strokeDashCap(let c)?: currentCap = c
            default: currentCap = nil
            }
            for (title, cap) in Self.caps {
                popup.addItem(withTitle: title + (cap == d ? " (default)" : ""))
                popup.lastItem?.representedObject = cap.rawValue
            }
            popup.selectItem(at: Self.caps.firstIndex { $0.1 == (currentCap ?? d) } ?? 0)
            popup.onAction { [weak controller] c in
                guard let raw = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String,
                      let cap = ShapeLineCap(rawValue: raw) else { return }
                controller?.editShape(key, meter: meter) { s in apply(&s, cap == d && currentCap == nil ? nil : cap) }
            }
            return popup
        }
        rows.append(InspectorRow(label: label("Start cap"), control: capPopup("shape-start-cap", .strokeStartCap, default: .flat) {
            $0.setStrokeStartCap($1) }))
        rows.append(InspectorRow(label: label("End cap"), control: capPopup("shape-end-cap", .strokeEndCap, default: .flat) {
            $0.setStrokeEndCap($1) }))
        rows.append(InspectorRow(label: label("Dash cap"), control: capPopup("shape-dash-cap", .strokeDashCap, default: .flat) {
            $0.setStrokeDashCap($1) }))
        let join = NSPopUpButton()
        join.identifier = NSUserInterfaceItemIdentifier("shape-join")
        var currentJoin: ShapeLineJoin = .miter
        var limit: String?
        if case .strokeLineJoin(let j, let l)? = spec.modifier(.strokeLineJoin) { currentJoin = j; limit = l }
        for (title, j) in Self.joins {
            join.addItem(withTitle: title + (j == .miter ? " (default)" : ""))
            join.lastItem?.representedObject = j.rawValue
        }
        join.selectItem(at: Self.joins.firstIndex { $0.1 == currentJoin } ?? 0)
        join.onAction { [weak controller] c in
            guard let raw = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String,
                  let j = ShapeLineJoin(rawValue: raw) else { return }
            controller?.editShape(key, meter: meter) { s in s.setStrokeLineJoin(j, miterLimit: limit) }
        }
        rows.append(InspectorRow(label: label("Join"), control: join))
        return rows
    }

    // MARK: Transform

    private func transformRows(_ item: ShapeItem, _ spec: ShapeSpec) -> [InspectorRow] {
        let key = item.key, meter = self.meter
        var rotate: (String, String?, String?)?
        if case .rotate(let a, let ax, let ay)? = spec.modifier(.rotate) { rotate = (a, ax, ay) }
        var scale: (String, String?, String?, String?)?
        if case .scale(let x, let y, let ax, let ay)? = spec.modifier(.scale) { scale = (x, y, ax, ay) }
        var skew: (String, String?, String?, String?)?
        if case .skew(let x, let y, let ax, let ay)? = spec.modifier(.skew) { skew = (x, y, ax, ay) }
        var offset: (String, String?)?
        if case .offset(let x, let y)? = spec.modifier(.offset) { offset = (x, y) }

        var rows: [InspectorRow] = []
        rows.append(InspectorRow(label: label("Rotate", tooltip: "Degrees, clockwise"), control: angleControl(item, "Rotate", value: rotate?.0, orientation: true) { s, v in
            s.setRotate(v, anchorX: rotate?.1, anchorY: rotate?.2)
        }))
        func field(_ caption: String, _ value: String?, placeholder: String, id: String,
                   _ apply: @escaping (inout ShapeSpec, String?) -> Void) -> NSView {
            let written = value ?? ""
            let control: NSView
            if LenientNumberFormatter.isExpression(written) {
                let pill = PillView(name: controller?.wholeVariable(written), value: written, symbol: "function")
                pill.toolTip = written
                control = pill
            } else {
                let f = NumberField(written, placeholder: placeholder, min: nil, max: nil)
                f.identifier = NSUserInterfaceItemIdentifier(id)
                f.onCommit = { [weak controller] v in
                    controller?.editShape(key, meter: meter) { s in apply(&s, v.isEmpty ? nil : v) }
                }
                control = f
            }
            return EditorStyle.hstack([EditorStyle.caption(caption), control], spacing: 5)
        }
        // Scale: X and Y (Y defaults to X), flips negate them.
        let sx = scale?.0 ?? "", sy = scale?.1
        let scaleX = field("X", scale?.0, placeholder: "1", id: "shape-scale-x") { s, v in
            s.setScale(v ?? (sy != nil ? "1" : nil), sy, anchorX: scale?.2, anchorY: scale?.3)
        }
        let scaleY = field("Y", sy, placeholder: "same", id: "shape-scale-y") { s, v in
            s.setScale(sx.isEmpty ? "1" : sx, v, anchorX: scale?.2, anchorY: scale?.3)
        }
        rows.append(InspectorRow(label: label("Scale"), control: EditorStyle.pair(scaleX, scaleY)))
        func flipButton(_ symbol: String, _ tip: String, _ id: String, horizontal: Bool) -> NSButton {
            let b = NSButton(image: EditorStyle.image(symbol, size: 12) ?? NSImage(), target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.controlSize = .small
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.onAction { [weak controller] _ in
                controller?.editShape(key, meter: meter) { s in
                    func negate(_ v: String) -> String {
                        let t = v.trimmingCharacters(in: .whitespaces)
                        if let n = Double(t) { return GeometryEdit.format(-n) }
                        return t.hasPrefix("-") ? String(t.dropFirst()) : "(-\(t))"
                    }
                    // The scale as it is now (the committed code may have changed it since the card was built).
                    var current: (String, String?, String?, String?)?
                    if case .scale(let x, let y, let ax, let ay)? = s.modifier(.scale) { current = (x, y, ax, ay) }
                    let x = (current?.0 ?? "").isEmpty ? "1" : current!.0
                    let y = current?.1 ?? x
                    if horizontal {
                        s.setScale(negate(x), y == x && current?.1 == nil ? x : y, anchorX: current?.2, anchorY: current?.3)
                    } else {
                        s.setScale(x, negate(y), anchorX: current?.2, anchorY: current?.3)
                    }
                }
            }
            return b
        }
        rows.append(InspectorRow(label: label("Flip"), control: EditorStyle.hstack([
            flipButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally", "shape-flip-h", horizontal: true),
            flipButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically", "shape-flip-v", horizontal: false),
            EditorStyle.spacer()], spacing: 4)))
        let kx = skew?.0 ?? "", ky = skew?.1
        rows.append(InspectorRow(label: label("Skew", tooltip: "Degrees"), control: EditorStyle.pair(
            field("X", skew?.0, placeholder: "0", id: "shape-skew-x") { s, v in
                s.setSkew(v ?? (ky != nil ? "0" : nil), ky, anchorX: skew?.2, anchorY: skew?.3)
            },
            field("Y", ky, placeholder: "0", id: "shape-skew-y") { s, v in
                s.setSkew(kx.isEmpty ? "0" : kx, v, anchorX: skew?.2, anchorY: skew?.3)
            })))
        let ox = offset?.0 ?? "", oy = offset?.1
        rows.append(InspectorRow(label: label("Offset"), control: EditorStyle.pair(
            field("X", offset?.0, placeholder: "0", id: "shape-offset-x") { s, v in s.setOffset(v ?? (oy != nil ? "0" : nil), oy) },
            field("Y", oy, placeholder: "0", id: "shape-offset-y") { s, v in s.setOffset(ox.isEmpty ? "0" : ox, v) })))
        return rows
    }

    // MARK: Summary

    /// "Rounded rectangle 120 × 48", "Circle ⌀ 40", "Line 224 long"… from the numbers the engine uses.
    static func summary(_ item: ShapeItem) -> String {
        guard let spec = item.spec else { return "Not a shape" }
        if let unknown = spec.unknownType { return "“\(unknown)” is not a type" }
        let r = item.resolved ?? spec
        func n(_ s: String?) -> Double? { s.flatMap(OptionValue.number) }
        func f(_ v: Double?) -> String {
            guard let v = v.map(abs) else { return "ƒ" }
            return v >= 10 ? String(Int(v.rounded())) : GeometryEdit.format((v * 10).rounded() / 10)
        }
        switch spec.kind {
        case .rectangle:
            let g = r.rectangle
            let rounded = (n(g?.radiusX) ?? 0) > 0
            return "\(rounded ? "Rounded rectangle" : "Rectangle") \(f(n(g?.width))) × \(f(n(g?.height)))"
        case .ellipse:
            let g = r.ellipse
            let rx = n(g?.radiusX), ry = n(g?.radiusY) ?? rx
            if let rx, let ry, rx == ry { return "Circle ⌀ \(f(rx * 2))" }
            return "Ellipse \(f(rx.map { $0 * 2 })) × \(f(ry.map { $0 * 2 }))"
        case .line:
            if let g = r.line, let x1 = n(g.startX), let y1 = n(g.startY), let x2 = n(g.endX), let y2 = n(g.endY) {
                return "Line \(f(((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot())) long"
            }
            return "Line"
        case .arc: return r.arc?.isClosed == true ? "Arc, closed" : "Arc"
        case .curve: return r.curve?.isCubic == true ? "Curve (two control points)" : "Curve"
        case .path, .path1: return spec.kind.title + (spec.pathOption.map { " · \(LayerNaming.humanized($0))" } ?? "")
        case .combine:
            // In words ("2 shapes joined", "Overlap of 2 shapes"); the keys and steps as written in the tooltip.
            let n = spec.combineSteps.count + 1
            let modes = Set(spec.combineSteps.map(\.operation.keyword).map { $0.lowercased() })
            if modes == ["union"] { return "\(n) shapes joined" }
            if modes == ["intersect"] { return "Overlap of \(n) shapes" }
            if modes == ["xor"] { return "\(n) shapes without their overlap" }
            if modes == ["exclude"] { return "Shape with \(n - 1) cut out" }
            return "\(n) shapes combined"
        }
    }
}

/// A row of the shape list: highlighted when selected, click to select.
final class ClickableRow: NSStackView {
    var onClick: (() -> Void)?
    private let isSelected: Bool

    init(_ views: [NSView], selected: Bool) {
        isSelected = selected
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        for v in views { addArrangedSubview(v) }
        // (Its views differ in height: the color dot, the icon, the words.)
        EditorStyle.holdVerticalInsets(self)
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
    }

    /// The whole row is the button (its labels and icons do not take the click).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A small round color sample.
final class SwatchDot: NSView {
    let color: RGBA

    init(color: RGBA) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 10).isActive = true
        heightAnchor.constraint(equalToConstant: 10).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        color.nsColor.setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.2).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// Color picking for colors inside a shape or a gradient: the whole option text changes, so the color panel reports
/// to a closure that builds it. Every pick is a live preview (`previewProperty`), written by the preview's own timer
/// when the panel rests, or at once when the panel closes; closing it without picking writes nothing.
///
/// The panel is shared with the inspector's own swatches, and the inspector is rebuilt after every write, so the
/// picker keeps track of whom the panel is working for: the swatch that opened it (`active`), taken over by the
/// rebuilt swatch for the same color, and forgotten when another swatch takes the panel (`relinquish`) or when a
/// rebuild no longer shows that color (another layer selected, the shape removed).
final class ShapeColorPicker: NSObject {
    static let shared = ShapeColorPicker()
    private final class Entry {
        weak var swatch: SwatchButton?
        weak var controller: InspectorWindowController?
        /// What the swatch edits ("meter/shape2/fill", "meter/shapefill/stop-1").
        let identity: String
        let handler: (RGBA, Bool) -> Void

        init(_ swatch: SwatchButton, _ controller: InspectorWindowController?, _ identity: String,
             _ handler: @escaping (RGBA, Bool) -> Void) {
            self.swatch = swatch
            self.controller = controller
            self.identity = identity
            self.handler = handler
        }
    }

    private var entries: [Entry] = []
    /// The color the panel is picking for (nil: the panel works for someone else, or for no one).
    private var active: Entry?
    private var observing = false

    /// Remembers what picking a color for `swatch` changes (swatches that are gone are forgotten). A swatch for the
    /// color being picked (the same `identity`, rebuilt after a write) takes the pick over.
    func register(_ swatch: SwatchButton, identity: String, controller: InspectorWindowController?,
                  _ handler: @escaping (RGBA, Bool) -> Void) {
        entries.removeAll { $0.swatch == nil || $0.swatch === swatch }
        let entry = Entry(swatch, controller, identity.lowercased(), handler)
        entries.append(entry)
        if let active, active.identity == entry.identity, active.controller === controller { self.active = entry }
    }

    private func entry(for swatch: SwatchButton) -> Entry? {
        entries.first { $0.swatch === swatch }
    }

    /// What the color panel is picking for (self-tests): the identity, or nil.
    var activeIdentity: String? { active?.identity }

    @objc func swatchClicked(_ sender: SwatchButton) {
        guard activate(sender) else { return }
        // The inspector's own color edit (if any) was written by `activate`; the panel now reports here.
        InspectorColorPanel.shared.release()
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil)
        panel.color = sender.color?.nsColor ?? .white
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(panelClosed), name: NSWindow.willCloseNotification,
                                                   object: panel)
        }
    }

    @objc func colorPicked(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        pickColor(RGBA(r: Double(c.redComponent) * 255, g: Double(c.greenComponent) * 255,
                       b: Double(c.blueComponent) * 255, a: Double(c.alphaComponent) * 255))
    }

    /// Makes the panel pick for `swatch` (a click, without the panel itself for self-tests).
    @discardableResult
    func activate(_ swatch: SwatchButton) -> Bool {
        guard let entry = entry(for: swatch) else { return false }
        // A color the inspector itself is picking is written before the panel changes hands.
        entry.controller?.commitPendingColor()
        active = entry
        return true
    }

    /// A color from the panel: previewed for the active swatch, if there still is one.
    func pickColor(_ rgba: RGBA) {
        guard let active, active.swatch != nil else { return }
        active.handler(rgba, false)
    }

    /// The panel closed: the pick ends, its pending preview is written now (nothing when nothing was picked).
    @objc func panelClosed() {
        guard let active else { return }
        self.active = nil
        active.controller?.commitPendingPreview()
    }

    /// Another swatch took the color panel: this picker's pick ends (a pending preview is still written by its timer).
    func relinquish() {
        active = nil
    }

    /// The inspector was rebuilt: a pick whose color it no longer shows ends.
    func inspectorRebuilt(_ controller: InspectorWindowController) {
        guard let active, active.controller === controller || active.controller == nil else { return }
        if active.swatch?.window == nil { self.active = nil }
    }

    /// Picks a color for a swatch as the color panel would, ending the pick (self-tests).
    func pick(_ rgba: RGBA, for swatch: SwatchButton) {
        entry(for: swatch)?.handler(rgba, true)
    }
}

// MARK: - Editing shapes

extension InspectorWindowController {
    /// The options of `meter`: the inspector's rows when it is the selected section (they include a live preview),
    /// else read from the skin. Edits always name their meter: the selection can change while the color panel or a
    /// preview timer still works for the one before.
    func shapeRows(of meter: String) -> [Row] {
        if selectedSection?.caseInsensitiveCompare(meter) == .orderedSame { return rows }
        return rows(of: meter, kind: .meter)
    }

    /// The Shape options of `meter`, in drawing order. A shape whose type word is not a type (a typo) is read
    /// anyway (`ShapeSpec.unknownType`), so the editor can show it and offer the real types.
    func shapeItems(of meter: String) -> [ShapeEditorView.ShapeItem] {
        shapeRows(of: meter).compactMap { r -> ShapeEditorView.ShapeItem? in
            guard let i = ShapeSpec.index(ofOption: r.key) else { return nil }
            return ShapeEditorView.ShapeItem(key: r.key, index: i, row: r, spec: ShapeSpec.parse(r.raw, allowingUnknownType: true),
                                             resolved: ShapeSpec.parse(r.resolved, allowingUnknownType: true))
        }.sorted { $0.index < $1.index }
    }

    func shapeItem(_ key: String, of meter: String) -> ShapeEditorView.ShapeItem? {
        shapeItems(of: meter).first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// The named gradient option of `meter`, parsed.
    func gradient(_ name: String, of meter: String) -> GradientSpec? {
        shapeRows(of: meter).first { $0.key.caseInsensitiveCompare(name) == .orderedSame }.flatMap { GradientSpec.parse($0.raw) }
    }

    /// Changes one shape of `meter` and writes it (one undo step). The shape is read when the change is applied, not
    /// when the control was built: typed code, a value typed in a field or a live preview not written yet are
    /// committed first (`deferUntilEditsAreCommitted`), and the change applies on the next turn to what they left —
    /// so a click never writes an older version of the shape over them, and a value typed for a Combine step or a
    /// shape field is written before the steps or shapes are renumbered.
    func editShape(_ key: String, meter: String, _ change: @escaping (inout ShapeSpec) -> Void) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.editShape(key, meter: meter, change) }) { return }
        guard !inspectorState.isRebuilding, var spec = shapeItem(key, of: meter)?.spec else { return }
        change(&spec)
        writeShape(spec, key: key, meter: meter)
    }

    /// Previews a change of one shape (dials, held steppers, the color panel), read from the skin as it is (typed
    /// code is committed before the first step), and writes it when `finished` or after a pause.
    func previewShapeEdit(_ key: String, meter: String, finished: Bool, _ change: (inout ShapeSpec) -> Void) {
        if codeHasUncommittedChanges, !committingCode { guard flushCode() else { return } }
        guard var spec = shapeItem(key, of: meter)?.spec else { return }
        change(&spec)
        previewShape(spec, key: key, meter: meter, finished: finished)
    }

    /// Changes the named gradient option of `meter` and writes it (like `editShape`; `change` returns false to write
    /// nothing).
    func editGradient(_ name: String, meter: String, _ change: @escaping (inout GradientSpec) -> Bool) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.editGradient(name, meter: meter, change) }) { return }
        guard !inspectorState.isRebuilding, var g = gradient(name, of: meter), change(&g) else { return }
        commitPendingPreview()
        writeShapeOption(g.text, key: name, meter: meter, label: "Gradient")
    }

    /// Previews a change of a gradient option (its angle, a color from the panel).
    func previewGradientEdit(_ name: String, meter: String, finished: Bool, _ change: (inout GradientSpec) -> Void) {
        if codeHasUncommittedChanges, !committingCode { guard flushCode() else { return } }
        guard var g = gradient(name, of: meter) else { return }
        change(&g)
        previewProperty(PreviewTarget(section: meter, key: name, variable: nil, name: "Gradient"), value: g.text, finished: finished)
    }

    /// Writes one shape (where `writeShapeOption` says), one undo step.
    func writeShape(_ spec: ShapeSpec, key: String, meter: String) {
        guard !inspectorState.isRebuilding else { return }
        commitPendingPreview()
        writeShapeOption(spec.text, key: key, meter: meter, label: "Shape \(ShapeSpec.index(ofOption: key) ?? 1)")
    }

    /// Writes an option of a Shape layer (a shape, a gradient) where `ScopeResolver` says (`writeProperty`, §7.5) —
    /// except that a look in a file other widgets include too (System's tracks: `StyleTrack` in the shared
    /// Styles.inc) is never rewritten from a layer's page: the layer gets its own value, and the toast says so.
    func writeShapeOption(_ value: String, key: String, meter: String, label: String) {
        guard writesOwnShapeOption(meter: meter, key: key) else {
            return writeProperty(section: meter, key: key, value: value, variable: nil, label: label)
        }
        let who = displayName(ofSection: meter)
        commitPlainly([Edit(section: meter, key: key, value: value, own: true)], name: "Change \(label) of \(who)",
                      message: "Changed \(who) only. Other widgets share its look, so the look stays as it is.")
    }

    /// Whether a Shape layer's option is defined by a look in a file other widgets share (see `writeShapeOption`):
    /// where the files define it, so a live preview of the option is not taken for its definition.
    func writesOwnShapeOption(meter: String, key: String) -> Bool {
        guard let skin, let m = skin.meter(named: meter), m.type.lowercased() == "shape" else { return false }
        let defined = skin.fileEditTarget(section: meter, key: key)
        guard defined.section.caseInsensitiveCompare(m.name) != .orderedSame else { return false }
        return !Self.isWidgetFile(defined.file, of: skin)
    }

    /// Previews a shape (dials, held steppers, the color panel) and writes it when `finished` or after a pause.
    func previewShape(_ spec: ShapeSpec, key: String, meter: String, finished: Bool) {
        previewProperty(PreviewTarget(section: meter, key: key, variable: nil, name: "Shape \(ShapeSpec.index(ofOption: key) ?? 1)"),
                        value: spec.text, finished: finished)
    }

    /// Changes a shape's type, carrying its geometry over and keeping its modifiers. A type word that is not a type
    /// (a typo) is replaced by the chosen one, and nothing else changes.
    func setShapeKind(_ kind: ShapeSpec.Kind, key: String, meter: String) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.setShapeKind(kind, key: key, meter: meter) }) { return }
        guard let spec = shapeItem(key, of: meter)?.spec, spec.kind != kind || spec.unknownType != nil else { return }
        writeShape(spec.unknownType != nil ? spec.withType(kind) : spec.converted(to: kind), key: key, meter: meter)
    }

    /// Fill: None, one color, or a linear / radial gradient (a named option, created next to the shape when needed).
    func setShapeFillMode(_ mode: ShapeEditorView.FillMode, key: String, meter: String) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.setShapeFillMode(mode, key: key, meter: meter) }) { return }
        guard let skin, let item = shapeItem(key, of: meter), var spec = item.spec else { return }
        switch mode {
        case .none:
            spec.removeFill()
            writeShape(spec, key: key, meter: meter)
        case .color:
            let previous: String? = {
                if case .color(let c)? = spec.fill, OptionValue.color(c).map({ $0.a > 0 }) ?? true { return c }
                return nil
            }()
            spec.setFill(.color(previous ?? "255,255,255,255"))
            writeShape(spec, key: key, meter: meter)
        case .linear, .radial:
            let radial = mode == .radial
            let existing = spec.fill?.gradientOption
            var g = existing.flatMap { self.gradient($0, of: meter) } ?? GradientSpec(head: [], stops: [])
            if g.stops.isEmpty {
                let first: String = { if case .color(let c)? = spec.fill { return c } else { return "255,255,255,255" } }()
                g.stops = [GradientSpec.Stop(color: first, position: "0.0"), GradientSpec.Stop(color: "0,0,0,255", position: "1.0")]
            }
            if radial != (spec.fill?.isRadial ?? !radial) || existing == nil {
                g.head = radial ? ["0", "0"] : ["270"]
            }
            let taken = Set(shapeRows(of: meter).map { $0.key.lowercased() })
            var name = existing ?? "\(key)Fill"
            if existing == nil {
                var n = 2
                while taken.contains(name.lowercased()) { name = "\(key)Fill\(n)"; n += 1 }
            }
            spec.setFill(radial ? .radialGradient(name, linearLight: false) : .linearGradient(name, linearLight: false))
            // The gradient goes where the shape is defined, so the shape finds it — both on the layer itself when the
            // shape comes from a look other widgets share (`writeShapeOption`).
            let own = writesOwnShapeOption(meter: meter, key: key)
            let shapeTarget = own ? skin.ownTarget(section: meter, key: key) : skin.editTarget(section: meter, key: key)
            let gradientTarget = own ? skin.ownTarget(section: meter, key: name)
                : existing != nil ? skin.editTarget(section: meter, key: name) : shapeTarget
            writeKeys([KeyWrite(file: shapeTarget.file, section: shapeTarget.section, key: key, value: spec.text),
                       KeyWrite(file: gradientTarget.file, section: gradientTarget.section, key: name, value: g.text)],
                      name: radial ? "Radial Gradient" : "Linear Gradient",
                      message: showsDetails ? "Gradient \(name)" : "The fill is now a gradient")
        }
    }

    /// Stroke on (the default width 1 again) or off (`StrokeWidth 0`).
    func setShapeStroke(_ on: Bool, key: String, meter: String) {
        editShape(key, meter: meter) { spec in
            if on {
                let width = spec.strokeWidth.flatMap { OptionValue.number($0) }
                if width == nil || width == 0 { spec.setStrokeWidth(nil) }
            } else {
                spec.setStrokeWidth("0")
            }
        }
    }

    /// Adds a shape of `kind` after the others, sized to the layer, and selects it.
    func addShape(_ kind: ShapeSpec.Kind, meter: String) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.addShape(kind, meter: meter) }) { return }
        guard let m = skin?.meter(named: meter) else { return }
        let items = shapeItems(of: meter)
        let next = (items.map(\.index).max() ?? 0) + 1
        let key = ShapeSpec.optionKey(next)
        let w = m.frame.width > 4 ? GeometryEdit.format(min(m.frame.width, 400)) : "100"
        let h = m.frame.height > 4 ? GeometryEdit.format(min(m.frame.height, 400)) : "40"
        var spec = ShapeSpec(kind: .rectangle, params: ["0", "0", w, h])
        if kind != .rectangle { spec = spec.converted(to: kind) }
        if spec.isClosed != false { spec.setFill(.color("255,255,255,255")) }
        spec.setStrokeWidth(kind == .line || kind == .arc || kind == .curve ? "2" : "0")
        if kind == .line || kind == .arc || kind == .curve { spec.setStroke(.color("255,255,255,255")) }
        inspectorState.expandedShapes[meter.lowercased()] = key
        guard let skin else { return }
        let target = skin.ownTarget(section: meter, key: key)
        writeKeys([KeyWrite(file: target.file, section: target.section, key: key, value: spec.text)],
                  name: "Add \(kind.title)",
                  message: showsDetails ? "\(kind.title) added as \(key)" : "Added \(LayerNaming.inSentence(ShapeSpec.Kind.plainName(kind)))")
    }

    /// Removes a shape; the ones after it move up (Combine references follow).
    func removeShape(_ key: String, meter: String) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.removeShape(key, meter: meter) }) { return }
        let order = shapeItems(of: meter).map(\.key).filter { $0.caseInsensitiveCompare(key) != .orderedSame }
        applyShapeOrder(order, meter: meter, name: "Remove Shape", select: nil)
    }

    /// Moves a shape back (-1, drawn earlier) or forward (+1, drawn later).
    func moveShape(_ key: String, by offset: Int, meter: String) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.moveShape(key, by: offset, meter: meter) }) { return }
        var order = shapeItems(of: meter).map(\.key)
        guard let i = order.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { return }
        let j = i + offset
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        applyShapeOrder(order, meter: meter, name: offset < 0 ? "Move Shape Back" : "Move Shape Forward", select: key)
    }

    /// Renumbers the meter's shapes into `order` (`ShapeSpec.renumber`: Combine references rewritten), one undo step.
    /// Shapes all defined in one place (the layer or one style) are rewritten there; shapes defined in different
    /// places are written on the layer itself (a removed shape that only a style defines cannot go: the style would
    /// bring it back, so nothing is written and the toast says why).
    ///
    /// The shapes are rewritten as the files define them (`SkinSection.fileOption`), never with a value the running
    /// skin set (`!SetOption` stores its text with the variables already replaced) or a live preview: moving a shape
    /// must not turn `#Variables#` of the shapes after it into literals. A shape only the running skin defines is not
    /// in any file and is left out.
    func applyShapeOrder(_ order: [String], meter: String, name: String, select moved: String?) {
        commitPendingPreview()
        guard let skin, let section = skin.section(named: meter) else { return }
        let fileItems = shapeItems(of: meter).compactMap { item -> (key: String, raw: String)? in
            section.fileOption(item.key).map { (item.key, $0) }
        }
        let fileKeys = Set(fileItems.map { $0.key.lowercased() })
        let runtime = shapeItems(of: meter).filter { $0.row.style == .runtime }.map(\.key)
        let result = ShapeSpec.renumber(fileItems.map { ShapeOption($0.key, $0.raw) },
                                        newOrder: order.filter { fileKeys.contains($0.lowercased()) })
        let targets = fileItems.map { skin.fileEditTarget(section: meter, key: $0.key) }
        let shared = targets.first.flatMap { first in targets.allSatisfy { $0 == first } ? first : nil }
        var writes: [KeyWrite] = []
        let own = skin.ownTarget(section: meter, key: "Shape")
        for o in result.options {
            let current = fileItems.first { $0.key.caseInsensitiveCompare(o.key) == .orderedSame }
            if current?.raw == o.value { continue }
            let t = shared ?? own
            writes.append(KeyWrite(file: t.file, section: t.section, key: o.key, value: o.value))
        }
        // A key a shared style also defines would come back after its removal from the layer.
        let styles = OptionValue.list(skin.meter(named: meter)?.rawOption("MeterStyle") ?? "")
        func styleDefines(_ key: String) -> Bool {
            styles.contains { skin.document.section(named: $0)?.value(forKey: key) != nil }
        }
        let ownSection = skin.section(named: meter)?.name ?? meter
        for key in result.removedKeys {
            if let shared, shared.section.caseInsensitiveCompare(ownSection) != .orderedSame {
                writes.append(KeyWrite(file: shared.file, section: shared.section, key: key, value: nil))
                continue
            }
            guard let file = skin.ownDefinitionFile(section: meter, key: key), !styleDefines(key) else {
                toast.show("This part comes from a look, so it can't be removed from this layer — change it in the code", error: true)
                return
            }
            writes.append(KeyWrite(file: file, section: ownSection, key: key, value: nil))
        }
        if let moved, let old = fileItems.firstIndex(where: { $0.key.caseInsensitiveCompare(moved) == .orderedSame }),
           let position = order.filter({ fileKeys.contains($0.lowercased()) })
            .firstIndex(where: { $0.caseInsensitiveCompare(fileItems[old].key) == .orderedSame }) {
            inspectorState.expandedShapes[meter.lowercased()] = ShapeSpec.optionKey(position + 1)
        } else {
            inspectorState.expandedShapes[meter.lowercased()] = nil
        }
        // In words (toasts never name a section's keys): the option names only with Rainmeter Details.
        var notes = showsDetails ? result.notes : []
        if !runtime.isEmpty {
            notes.append(showsDetails ? "\(runtime.joined(separator: ", ")) changed while the widget ran; the files’ version was kept"
                : "\(runtime.count == 1 ? "a part" : "some parts") changed while the widget ran; the files’ version was kept")
        }
        let done = name.hasPrefix("Remove") ? "Removed the part" : "Reordered the parts"
        writeKeys(writes, name: name, message: notes.isEmpty ? done : done + " · " + notes.joined(separator: "; "))
    }
}
