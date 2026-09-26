import AppKit
import DesksetCore

// The inspector's selection pages (docs/editor-friendly.md §7–8): what it shows for a layer, a group of repeated
// layers, several layers and a live data item. Every page starts with an identity strip (a breadcrumb, a picture, the
// layer's name and one sentence, its buttons), then calm cards that show 3–5 essential settings and end in one
// "More {Kind} Options" disclosure that says what it holds and how many of its settings are in use.
//
// This file holds what the pages share: their per-window state, the identity strip, the card builder and the
// Position and Size card. The pages themselves are in EditorLayerPages.swift (layers, groups, several) and
// EditorDataPage.swift (live data).

// MARK: - State kept between rebuilds

/// What the selection pages remember while the inspector is rebuilt (the rest is in `InspectorState.disclosures`,
/// which the inspector's inputs include, so opening a disclosure rebuilds it).
final class SelectionPageState {
    /// Selections shown so far in this window: the nudge hint is shown for the first three.
    var selections = 0
    var lastSelection = ""
    /// Recent values of live data (section lowercased → values, oldest first) for the RIGHT NOW sparkline.
    var history: [String: [Double]] = [:]
    /// A color being picked for several layers at once: previewed, written after a pause.
    var multiColor: (sections: [String], key: String, value: String, name: String)?
    var multiColorTimer: Timer?
    /// The swatches of colors that several layers are edited with together (a group's Fill): their picks go to
    /// `previewSeveralColor`.
    let severalSwatches = NSHashTable<SwatchButton>.weakObjects()

    deinit { multiColorTimer?.invalidate() }
}

private var selectionPageStateKey: UInt8 = 0

extension InspectorWindowController {
    var pageState: SelectionPageState {
        if let state = objc_getAssociatedObject(self, &selectionPageStateKey) as? SelectionPageState { return state }
        let state = SelectionPageState()
        objc_setAssociatedObject(self, &selectionPageStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// View ▸ Show Rainmeter Details: option names, section names, every disclosure open.
    var showsDetails: Bool { app.state.editor.showIniNames }

    /// The widget's name ("Audio Visualizer"): its Metadata name, else the last part of its config.
    func widgetName(_ skin: Skin) -> String {
        let name = ManageModel.metadataValue(skin.metadata, "Name") ?? ""
        return name.isEmpty ? String(skin.config.split(separator: "\\").last ?? Substring(skin.config)) : name
    }

    /// Counts a new selection (for the nudge hint, shown with the first three).
    func noteSelectionShown(_ key: String) {
        guard key != pageState.lastSelection else { return }
        pageState.lastSelection = key
        pageState.selections += 1
    }

    // MARK: - Names

    /// A kind in the plural ("bars", "texts", "line graphs").
    static func pluralKind(_ kind: String, count: Int) -> String {
        count == 1 ? kind.lowercased() : LayerNaming.kindPlural(kind)
    }

    /// "16 bars", "3 texts", "2 layers" (mixed kinds).
    func countedLayers(_ names: [String], in skin: Skin) -> String {
        let kinds = Set(names.compactMap { skin.meter(named: $0).map(LayerNaming.kindNoun) })
        let kind = kinds.count == 1 ? kinds.first! : "Layer"
        return "\(names.count) \(Self.pluralKind(kind, count: names.count))"
    }

    /// A shared value's name in words: "BarW" → "Bar width", "BarGap" → "Bar gap", "Left" → "Left".
    static func sharedValueName(_ variable: String) -> String {
        let words = LayerNaming.humanized(variable).split(separator: " ").map(String.init)
        let expanded = words.enumerated().map { i, w -> String in
            switch w.lowercased() {
            case "w" where i > 0: return "width"
            case "h" where i > 0: return "height"
            default: return w
            }
        }
        return expanded.joined(separator: " ")
    }

    /// The name of live data in sentences ("peak level"): its name with a lowercase first letter, unless it starts
    /// with an acronym ("CPU usage").
    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        let second = text.dropFirst().first
        if second?.isUppercase == true { return text }
        return first.lowercased() + text.dropFirst()
    }

    // Title Case for undo names and buttons ("Show CPU usage" → "Show CPU Usage"): `titleCase(_:)` in
    // EditorPropertyWriting.swift.

    /// The name of live data as the pages show it.
    func dataName(_ m: Measure, in skin: Skin) -> String {
        let name = LayerNaming.data(m, in: skin).name
        guard name == LayerNaming.humanized(m.name) else { return name }
        // Until the naming rules know a type, its plain description reads better than the section's name — unless
        // other live data has the same description (16 sound bands would all be "Sound").
        let title = EditorStyle.describe(m).title
        let shared = skin.measures.contains { $0 !== m && EditorStyle.describe($0).title == title }
        return shared ? name : title
    }

    // MARK: - Layers of the widget

    /// The layer the editor calls "Background" (drawn first, covering the widget): `LayerNaming`'s, else a Shape or
    /// Picture drawn first that covers at least 90% of the widget.
    func backgroundLayer(in skin: Skin) -> String? {
        if let name = LayerNaming.background(in: skin) { return name }
        guard let first = skin.meters.first(where: { !$0.hidden }), ["shape", "image"].contains(first.type.lowercased()),
              skin.width > 0, skin.height > 0 else { return nil }
        let f = first.frame
        let w = max(0, min(f.maxX, skin.width) - max(f.x, 0)), h = max(0, min(f.maxY, skin.height) - max(f.y, 0))
        return w * h >= 0.9 * skin.width * skin.height ? first.name : nil
    }

    /// Layers whose options use a shared value (`#Name#`), directly or through their look — and those it reaches
    /// through live data (a formula's position): the value's users, counted as the widget page counts them
    /// (`ValueUsageIndex.reach`, "Left · 10 layers").
    func layersUsing(variable: String, in skin: Skin) -> [String] {
        let index = valueUsages(skin)
        let usages = index.reach(index.users(ofVariable: variable)).filter { skin.meter(named: $0) != nil }
        if !usages.isEmpty { return usages }
        return skin.meters.filter { m in
            skin.inspectedOptions(ofSection: m.name).contains { o in
                o.variables.contains { $0.caseInsensitiveCompare(variable) == .orderedSame }
            }
        }.map(\.name)
    }

    /// The meters in a run of repeated layers (docs/editor-friendly.md §5.2) that `names` is exactly: from
    /// `LayerSeries`, or — for a selection that follows the same rules itself — the selection. nil otherwise.
    func groupSeries(for names: [String], in skin: Skin) -> Series? {
        let wanted = Set(names.map { $0.lowercased() })
        if let s = LayerSeries.detect(in: skin).first(where: { $0.kind == .layers && Set($0.members.map { $0.lowercased() }) == wanted }) {
            return s
        }
        // The same rules on the selection: 3 or more consecutive layers in file order, the same type and looks, no
        // container, names that differ only by a trailing number.
        let meters = skin.meters.filter { wanted.contains($0.name.lowercased()) }
        guard meters.count >= 3, meters.count == wanted.count,
              let first = skin.meters.firstIndex(where: { $0 === meters[0] }),
              first + meters.count <= skin.meters.count,
              zip(skin.meters[first..<(first + meters.count)], meters).allSatisfy({ $0 === $1 }) else { return nil }
        func stem(_ name: String) -> String? {
            let digits = name.reversed().prefix { $0.isNumber }.count
            return digits == 0 ? nil : String(name.dropLast(digits)).lowercased()
        }
        let stems = Set(meters.map { stem($0.name) })
        let looks = Set(meters.map { OptionValue.list($0.rawOption("MeterStyle") ?? "").map { $0.lowercased() }.joined(separator: "|") })
        guard stems.count == 1, stems.first! != nil, looks.count == 1,
              Set(meters.map { $0.type.lowercased() }).count == 1, meters.allSatisfy({ $0.container == nil }) else { return nil }
        return Series(kind: .layers, members: meters.map(\.name))
    }

    /// The run of repeated layers `name` belongs to (for the breadcrumb of a member).
    func series(containing name: String, in skin: Skin) -> Series? {
        let detected = LayerSeries.detect(in: skin).filter { $0.kind == .layers }
        return (detected.isEmpty ? fallbackLayerSeries(in: skin) : detected).first { $0.contains(name) }
    }

    /// Runs of layers by the rules of §5.2 (until `LayerSeries` finds them): 3 or more consecutive layers, the same
    /// type and looks, no container, names that differ only by a trailing number.
    func fallbackLayerSeries(in skin: Skin) -> [Series] {
        var result: [Series] = []
        var run: [Meter] = []
        func key(_ m: Meter) -> String? {
            let digits = m.name.reversed().prefix { $0.isNumber }.count
            guard digits > 0, m.container == nil, !m.isContainer else { return nil }
            let looks = OptionValue.list(m.rawOption("MeterStyle") ?? "").map { $0.lowercased() }.joined(separator: "|")
            return [String(m.name.dropLast(digits)).lowercased(), m.type.lowercased(), looks].joined(separator: "\u{1F}")
        }
        func flush() {
            if run.count >= 3 { result.append(Series(kind: .layers, members: run.map(\.name))) }
            run = []
        }
        for m in skin.meters {
            if let k = key(m), let last = run.last, key(last) == k {
                run.append(m)
            } else {
                flush()
                if key(m) != nil { run = [m] }
            }
        }
        flush()
        return result
    }

    /// The run of repeated live data `name` belongs to.
    func dataSeries(containing name: String, in skin: Skin) -> Series? {
        if let s = LayerSeries.detect(in: skin).first(where: { $0.kind == .data && $0.contains(name) }) { return s }
        return fallbackDataSeries(in: skin).first { $0.contains(name) }
    }

    /// Runs of live data by the same rules (until `LayerSeries` finds them): consecutive, same type, same parent,
    /// names that differ only by a trailing number, at least 3.
    func fallbackDataSeries(in skin: Skin) -> [Series] {
        var result: [Series] = []
        var run: [Measure] = []
        func key(_ m: Measure) -> String? {
            let digits = m.name.reversed().prefix { $0.isNumber }.count
            guard digits > 0 else { return nil }
            return [String(m.name.dropLast(digits)).lowercased(), m.type.lowercased(),
                    (m.rawOption("Parent") ?? "").lowercased(), (m.rawOption("Type") ?? "").lowercased()].joined(separator: "|")
        }
        func flush() {
            if run.count >= 3 { result.append(Series(kind: .data, members: run.map(\.name))) }
            run = []
        }
        for m in skin.measures {
            if let k = key(m), let last = run.last, key(last) == k {
                run.append(m)
            } else {
                flush()
                if key(m) != nil { run = [m] }
            }
        }
        flush()
        return result
    }

    // MARK: - Pictures

    /// The pixels of `names` (drawn on the widget's own panel: its Background layer), cropped to their union and
    /// fitted into `size`; nil when they are too small to show (a glyph is shown then).
    func layerPicture(_ names: [String], in skin: Skin, size: NSSize = NSSize(width: 48, height: 48)) -> NSImage? {
        let meters = names.compactMap { skin.meter(named: $0) }
        guard !meters.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for m in meters {
            minX = min(minX, m.frame.x); minY = min(minY, m.frame.y)
            maxX = max(maxX, m.frame.maxX); maxY = max(maxY, m.frame.maxY)
        }
        guard maxX - minX >= 6, maxY - minY >= 6, maxX - minX < 20_000, maxY - minY < 20_000 else { return nil }
        // The area: the union with a margin, grown to the picture's proportions so nothing is stretched.
        var area = SkinRect(x: minX - 3, y: minY - 3, width: maxX - minX + 6, height: maxY - minY + 6)
        let aspect = Double(size.width / size.height)
        if area.width / area.height < aspect {
            let w = area.height * aspect
            area.x -= (w - area.width) / 2
            area.width = w
        } else {
            let h = area.width / aspect
            area.y -= (h - area.height) / 2
            area.height = h
        }
        let scale = 2.0 * Double(size.width) / area.width
        let pixelsWide = Int(size.width * 2), pixelsHigh = Int(size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        cg.translateBy(x: -CGFloat(area.x), y: -CGFloat(area.y))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let wanted = Set(meters.map { ObjectIdentifier($0) })
        if let background = backgroundLayer(in: skin).flatMap({ skin.meter(named: $0) }), !wanted.contains(ObjectIdentifier(background)) {
            SkinRenderer.drawMeter(background, cg)
        }
        for m in meters { SkinRenderer.drawMeter(m, cg) }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// A 48-point picture for the identity strip: the layer's pixels, else its kind's symbol.
    func stripPicture(image: NSImage?, symbol: String) -> NSView {
        let view = NSImageView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 9
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 48).isActive = true
        view.heightAnchor.constraint(equalToConstant: 48).isActive = true
        if let image {
            view.image = image
            view.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
        } else {
            view.image = EditorStyle.image(symbol, size: 20, weight: .regular)
            view.imageScaling = .scaleNone
            view.contentTintColor = .controlAccentColor
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        }
        view.identifier = NSUserInterfaceItemIdentifier("strip-picture")
        return view
    }

    // MARK: - Identity strip

    /// One button of the identity strip: small, bordered, icon and word.
    func stripButton(_ title: String, symbol: String, id: String, tooltip: String? = nil,
                     _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, image: EditorStyle.image(symbol, size: 11) ?? NSImage(), target: nil, action: nil)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.toolTip = tooltip
        b.onAction { _ in action() }
        return b
    }

    /// A "⋯" button that opens `menu()`.
    func stripMenuButton(id: String = "strip-more", _ menu: @escaping () -> NSMenu) -> NSButton {
        let b = NSButton(title: "", image: EditorStyle.image("ellipsis", size: 11, weight: .semibold) ?? NSImage(),
                         target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.toolTip = "More"
        b.setAccessibilityLabel("More")
        b.onAction { control in
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.height + 3), in: control)
        }
        return b
    }

    /// The identity strip (docs/editor-friendly.md §7.1): the breadcrumb (ancestors only, each a link), a picture, the
    /// name and one sentence, the buttons, then any `lines` (a warning, the Rainmeter details).
    func identityStrip(title: String, sentence: String, picture: NSView, crumbs: [(title: String, action: () -> Void)],
                       buttons: [NSView], lines: [NSView] = []) -> NSView {
        var column: [NSView] = []
        if !crumbs.isEmpty {
            let flow = FlowView()
            flow.spacing = 2
            flow.rowSpacing = 2
            flow.identifier = NSUserInterfaceItemIdentifier("breadcrumb")
            for (i, crumb) in crumbs.enumerated() {
                let b = NSButton(title: (i == 0 ? "‹ " : "› ") + crumb.title, target: nil, action: nil)
                b.isBordered = false
                b.font = .systemFont(ofSize: 11, weight: .medium)
                b.contentTintColor = .controlAccentColor
                b.lineBreakMode = .byTruncatingTail
                b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                b.identifier = NSUserInterfaceItemIdentifier("breadcrumb-\(i)")
                b.toolTip = "Select \(crumb.title)"
                let action = crumb.action
                b.onAction { _ in action() }
                flow.addSubview(b)
            }
            column.append(flow)
        }
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.isSelectable = false
        titleLabel.identifier = NSUserInterfaceItemIdentifier("strip-title")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sentenceLabel = NSTextField(wrappingLabelWithString: sentence)
        sentenceLabel.font = .systemFont(ofSize: 12)
        sentenceLabel.textColor = .secondaryLabelColor
        sentenceLabel.maximumNumberOfLines = 3
        sentenceLabel.isSelectable = false
        sentenceLabel.identifier = NSUserInterfaceItemIdentifier("strip-sentence")
        sentenceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = EditorStyle.vstack([titleLabel, sentenceLabel], spacing: 2)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Shorter than the picture, the words keep to their own height: the row pulls their bottom down to its own as
        // hard as they hug it (250), which leaves their height anywhere in between (ambiguous).
        texts.setHuggingPriority(.defaultHigh, for: .vertical)
        let top = EditorStyle.hstack([picture, texts], spacing: 12, alignment: .top)
        column.append(top)
        if !buttons.isEmpty {
            let row = EditorStyle.hstack(buttons + [EditorStyle.spacer()], spacing: 6)
            row.identifier = NSUserInterfaceItemIdentifier("strip-buttons")
            column.append(row)
        }
        column += lines
        let stack = EditorStyle.vstack(column, spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 4, right: 0)
        stack.identifier = NSUserInterfaceItemIdentifier("identity-strip")
        for v in column { v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -2).isActive = true }
        top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2).isActive = true
        // A line that is a stack of views (the Rainmeter details, a warning) is as wide as the strip: narrower, it would
        // hug its views as weakly as the strip pulls it to its own width (250), and be any width in between (ambiguous).
        for v in lines where v is NSStackView {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2).isActive = true
        }
        // Wrapping labels need to know how wide they may be.
        let width = EditorStyle.inspectorWidth - 32 - 2 - 48 - 12 - 16
        titleLabel.preferredMaxLayoutWidth = width
        sentenceLabel.preferredMaxLayoutWidth = width
        return stack
    }

    /// The strip's third line with Rainmeter Details on: `[MeterBand5] · Visualizer.ini:287 ↗`, and the looks.
    func detailsLine(section: String, looks: [String], skin: Skin) -> NSView? {
        guard showsDetails else { return nil }
        var parts: [NSView] = []
        if let location = skin.sources.location(section: section) {
            let link = NSButton(title: "[\(section)] · \(location.file.lastPathComponent):\(location.line)", target: nil, action: nil)
            link.isBordered = false
            link.font = .systemFont(ofSize: 11)
            link.contentTintColor = .controlAccentColor
            link.image = EditorStyle.image("arrow.up.forward", size: 9, weight: .semibold)
            link.imagePosition = .imageTrailing
            link.toolTip = "Show \(location.file.lastPathComponent) in the code editor"
            link.identifier = NSUserInterfaceItemIdentifier("source-link")
            link.onAction { [weak self] _ in self?.showInCode(location) }
            parts.append(link)
        }
        if !looks.isEmpty {
            let l = EditorStyle.label("Looks: " + looks.joined(separator: ", "), size: 11, color: .tertiaryLabelColor)
            l.identifier = NSUserInterfaceItemIdentifier("strip-looks")
            parts.append(l)
        }
        guard !parts.isEmpty else { return nil }
        return EditorStyle.vstack(parts, spacing: 2)
    }

    /// "⚠ Part of this layer is past the left edge…" [Fit Widget to Content], when the desktop cuts part of it off
    /// (the canvas's `cutOffEdges`): past the left or top edge the button fits the widget to its content
    /// (`fitWidgetToContent`, §9.10); past a fixed size it makes the widget bigger (`makeWidgetBigger`).
    func cutOffLine(_ names: [String], in skin: Skin) -> NSView? {
        let cut = names.compactMap { skin.meter(named: $0) }.map { Self.cutOffEdges(of: $0, in: skin) }.filter { !$0.isEmpty }
        guard !cut.isEmpty else { return nil }
        let edges = cut.reduce(CutOffEdges()) { $0.union($1) }
        let pastEdge = edges.contains(.left) || edges.contains(.top)
        let text: String
        if names.count == 1, let sentence = cutOffSentence(of: names[0]) {
            text = sentence
        } else if pastEdge {
            let edge = edges.contains(.left) && edges.contains(.top) ? "the left and top edges"
                : edges.contains(.left) ? "the left edge" : "the top edge"
            text = "Parts of these layers are past \(edge) and won't show on the desktop."
        } else {
            text = "Parts of these layers are outside the widget's fixed size and won't show on the desktop."
        }
        let warning = EditorStyle.issue(text, width: EditorStyle.inspectorWidth - 40)
        let fit = NSButton(title: pastEdge ? "Fit Widget to Content" : "Make Widget Bigger", target: nil, action: nil)
        fit.bezelStyle = .rounded
        fit.controlSize = .small
        fit.identifier = NSUserInterfaceItemIdentifier("fit-widget")
        fit.onAction { [weak self] _ in
            if pastEdge { self?.fitWidgetToContent() } else { self?.makeWidgetBigger() }
        }
        let stack = EditorStyle.vstack([warning, fit], spacing: 4)
        // (As wide as the line: see `identityStrip`.)
        warning.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.identifier = NSUserInterfaceItemIdentifier("cut-off")
        return stack
    }

    // Hide or show, lock or unlock: `setLayersHidden(_:hidden:)` and `setLayersLocked(_:locked:)` (EditorSidebar), the
    // same commands as the list's eye and lock and the layer menu.

    /// `commit` with a toast in plain words (it never names a file: docs/editor-friendly.md §3.3).
    func commitPlainly(_ edits: [Edit], name: String, message: String) {
        guard !edits.isEmpty else { return }
        if deferUntilCodeIsCommitted({ [weak self] in self?.commitPlainly(edits, name: name, message: message) }) { return }
        guard let skin else { return }
        let files = edits.map { e in (e.own ? skin.ownTarget(section: e.section, key: e.key) : skin.editTarget(section: e.section, key: e.key)).file }
        perform(name, files: files, message: { _ in message }) {
            for e in edits {
                if e.own {
                    try skin.writeOwnOption(section: e.section, key: e.key, value: e.value)
                } else {
                    try skin.writeOption(section: e.section, key: e.key, value: e.value)
                }
            }
        }
    }

    /// Sets and removes several keys as one undo step, with a toast in plain words.
    func writeKeysPlainly(_ writes: [KeyWrite], name: String, message: String) {
        guard !writes.isEmpty else { return }
        if deferUntilCodeIsCommitted({ [weak self] in self?.writeKeysPlainly(writes, name: name, message: message) }) { return }
        perform(name, files: writes.map(\.file), message: { _ in message }) { try Self.apply(writes) }
    }

    /// Selects the level above the selection, like the last part of the breadcrumb (Esc): member → group → widget.
    func selectParentLevel() {
        guard let skin else { return }
        if isMultiSelection {
            canvasSelectionChanged([])
        } else if let name = selectedSection, selectedKind == .meter, let s = series(containing: name, in: skin) {
            canvasSelectionChanged(s.members)
        } else if let name = selectedSection, selectedKind == .measure, let m = skin.measure(named: name),
                  let parent = m.rawOption("Parent"), skin.measure(named: parent) != nil {
            select(section: parent)
        } else {
            canvasSelectionChanged([])
        }
    }
}

// MARK: - Cards with essentials and "More … Options"

/// A button that reports the pointer entering and leaving it (hover outlines on the canvas).
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    /// The pointer is over it: a button taken away with the pointer still on it (the page rebuilt by its own click)
    /// never hears the pointer leave, so it takes back what its hover showed then.
    private var inside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        inside = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
        onHover?(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, inside {
            inside = false
            onHover?(false)
        }
    }
}

/// How a card is built from a schema group (`InspectorWindowController.friendlyCard`).
struct CardOptions {
    var section: String
    /// The card title (nil: the group's; "" none).
    var title: String?
    /// The card note (nil: the group's summary).
    var note: String?
    /// Rows drawn by the page itself (key lowercased): essential rows with a special control ("Fills toward"); nil
    /// from one: the usual control.
    var custom: [String: (InspectorWindowController.PropertyContext) -> InspectorRow?] = [:]
    /// Keys (lowercased) the card leaves out (shown elsewhere: Hidden in the identity strip).
    var skip: Set<String> = []
    /// Extra rows in "More" that are not schema properties ("Up and down"), with whether each is in use; first, or
    /// last with `extraMoreLast` ("When the value…").
    var extraMore: [(row: InspectorRow, inUse: Bool)] = []
    var extraMoreLast = false
    /// Views before the rows ("Right now 48 Hz"), after them.
    var top: [NSView] = []
    var bottom: [NSView] = []
    /// A badge in the title row when values come from a look.
    var lookBadge = true
    /// Only the "More" disclosure (the Layer card).
    var moreOnly = false

    init(section: String) { self.section = section }
}

extension InspectorWindowController {
    /// The context of a property of `section` (its row, the variable it is written as).
    func context(_ p: EditorSchema.Property, section: String, rows: [Row]) -> PropertyContext {
        let r = row(for: p, in: rows)
        let raw = r?.raw ?? ""
        let form = valueForm(p, raw: raw)
        let variable: String? = { if case .variable(let v) = form { return v } else { return nil } }()
        return PropertyContext(property: p, section: section, key: r?.key ?? p.key, row: r, variable: variable, form: form)
    }

    /// Whether a property is "in use": set (on the layer or by its look) to something other than its default. Quiet
    /// keys never are (docs/editor-friendly.md §2 P4).
    func isInUse(_ p: EditorSchema.Property, rows: [Row], groups: [EditorSchema.Group]) -> Bool {
        guard p.level != .quiet, let r = row(for: p, in: rows) else { return false }
        let value = r.resolved.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return false }
        let d = EditorSchema.defaultValue(of: p, in: groups, values: valueLookup(rows))
        if d.isEmpty { return true }
        if case .color = p.kind, let a = OptionValue.color(value), let b = OptionValue.color(d) { return a != b }
        if let a = OptionValue.number(value), let b = OptionValue.number(d) { return a != b }
        return EditorSchema.canonical(value, kind: p.kind) != EditorSchema.canonical(d, kind: p.kind)
    }

    /// The look (MeterStyle) most of `group`'s values of `section` come from, and the layers that use it.
    func lookBehind(_ group: EditorSchema.Group, section: String, rows: [Row]) -> (look: String, users: [String])? {
        guard let skin else { return nil }
        var counts: [String: Int] = [:]
        for p in group.properties {
            guard let r = row(for: p, in: rows), r.style == .inherited, let look = inheritedStyle(section: section, key: r.key)
            else { continue }
            counts[look, default: 0] += 1
        }
        guard let look = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (look, Self.styleUsers(look, in: skin))
    }

    /// "Look shared with 16 bars": hovering outlines the layers, clicking selects them.
    func lookBadge(look: String, users: [String]) -> NSView {
        guard let skin else { return NSView() }
        // Who else has these settings: the layers here, else the other widgets reading the look's file.
        let file = skin.sources.location(section: look)?.file
        let widgets = file.map { skin.isOwnFile($0) ? 0 : max(configsIncluding($0).count - 1, 0) } ?? 0
        let title = users.count > 1 ? "Look shared with \(countedLayers(users, in: skin))"
            : widgets > 0 ? "Look shared by \(widgets + 1) widgets" : "Uses a look"
        let b = HoverButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 10.5, weight: .medium)
        b.contentTintColor = .secondaryLabelColor
        b.image = EditorStyle.image("square.on.square", size: 9, weight: .semibold)
        b.imagePosition = .imageLeading
        b.identifier = NSUserInterfaceItemIdentifier("look-badge")
        b.toolTip = "These settings come from a look" + (users.count > 1 ? " \(users.count) layers share" : "")
            + ". Changing one here changes this layer only; the note after the change offers to change them all."
            + (showsDetails ? "\nLook: \(look)" : "")
        b.onHover = { [weak self] inside in
            guard let self else { return }
            self.canvas.hoverHighlight = inside ? users : []
            self.canvas.needsDisplay = true
        }
        b.onAction { [weak self] _ in
            guard let self, users.count > 1 else { return }
            self.canvas.hoverHighlight = []
            self.canvasSelectionChanged(users)
        }
        return b
    }

    /// A card title row: the small-caps title, and an accessory on the right.
    func cardTitleRow(_ title: String, accessory: NSView?) -> NSView {
        let label = EditorStyle.cardTitle(title)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        guard let accessory else { return label }
        accessory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = EditorStyle.hstack([label, EditorStyle.spacer(), accessory], spacing: 6)
        return row
    }

    /// The disclosure key of a card's "More": open state per card (widget-wide), closed per layer and card.
    static func moreKey(_ group: EditorSchema.Group) -> String { "more:" + group.moreLabel.lowercased() }

    /// Whether a card's "More" is open: with Rainmeter Details, when the user opened it, or when something in it is
    /// in use and the user did not close it for this layer.
    func isMoreOpen(_ group: EditorSchema.Group, section: String, inUse: Int) -> Bool {
        let key = Self.moreKey(group)
        let d = inspectorState.disclosures
        // "open/more:*": every More open (self-tests that reach every control of a kind).
        if showsDetails || d.contains("open/" + key) || d.contains("open/more:*") { return true }
        return inUse > 0 && !d.contains("closed/\(section.lowercased())/" + key)
    }

    func toggleMore(_ group: EditorSchema.Group, section: String, open: Bool) {
        let key = Self.moreKey(group)
        if open {
            inspectorState.disclosures.remove("open/" + key)
            inspectorState.disclosures.insert("closed/\(section.lowercased())/" + key)
        } else {
            inspectorState.disclosures.insert("open/" + key)
            inspectorState.disclosures.remove("closed/\(section.lowercased())/" + key)
        }
        rebuildKeepingScroll()
    }

    /// Opens a card's "More" (self-tests, links).
    func openMore(_ title: String) {
        inspectorState.disclosures.insert("open/more:" + title.lowercased())
        rebuildKeepingScroll()
    }

    /// The "More {Kind} Options" row: the title, what it holds, and "· N in use".
    func moreRow(_ group: EditorSchema.Group, section: String, inUse: Int, open: Bool) -> NSView {
        let button = EditorStyle.disclosure(group.moreLabel, open: open)
        button.identifier = NSUserInterfaceItemIdentifier("more-\(group.title)")
        button.contentTintColor = .labelColor
        button.onAction { [weak self] _ in self?.toggleMore(group, section: section, open: open) }
        var summary = group.moreSummary
        if inUse > 0 { summary += summary.isEmpty ? "\(inUse) in use" : " · \(inUse) in use" }
        let label = NSTextField(wrappingLabelWithString: summary)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.isSelectable = false
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = EditorStyle.inspectorWidth - 32 - 2 * EditorStyle.cardPadding - 16
        label.identifier = NSUserInterfaceItemIdentifier("more-summary-\(group.title)")
        label.isHidden = summary.isEmpty
        let stack = EditorStyle.vstack([button, label], spacing: 1)
        label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
        stack.identifier = NSUserInterfaceItemIdentifier("more-row-\(group.title)")
        return stack
    }

    /// A card for a schema group (docs/editor-friendly.md §7.2): the title (with the look badge), a note, the
    /// essential rows, then the "More" disclosure with the rest — opened by itself when something in it is in use.
    func friendlyCard(_ group: EditorSchema.Group, groups: [EditorSchema.Group], rows: [Row], options: CardOptions) -> NSView {
        let section = options.section
        let lookup = valueLookup(rows)
        let visible = group.properties.filter {
            EditorSchema.isVisible($0, in: groups, values: lookup) && !options.skip.contains($0.key.lowercased())
        }
        var views: [NSView] = []
        let title = options.title ?? group.title
        if !title.isEmpty, !options.moreOnly {
            let badge = options.lookBadge ? lookBehind(group, section: section, rows: rows).map { lookBadge(look: $0.look, users: $0.users) } : nil
            views.append(cardTitleRow(title, accessory: badge))
        }
        let note = options.note ?? group.summary
        if !note.isEmpty, !options.moreOnly { views.append(cardNote(note)) }
        views += options.top
        func build(_ p: EditorSchema.Property, dot: Bool) -> InspectorRow? {
            // A page's own control; nil: the usual one (an invalid or linked value the special control can't show).
            if let custom = options.custom[p.key.lowercased()], let row = custom(context(p, section: section, rows: rows)) {
                return row
            }
            return propertyRow(p, section: section, row: row(for: p, in: rows), groups: groups, friendly: true, dot: dot)
        }
        if !options.moreOnly {
            var essentials: [InspectorRow] = []
            for p in visible where p.level == .essential && p.partOf == nil {
                if let custom = options.custom[p.key.lowercased()], let row = custom(context(p, section: section, rows: rows)) {
                    essentials.append(row)
                    continue
                }
                // The usual controls: the row's own, then the options its special control would have held.
                if let row = build(p, dot: false) { essentials.append(row) }
                for part in visible where part.partOf?.caseInsensitiveCompare(p.key) == .orderedSame {
                    essentials.append(propertyRow(part, section: section, row: row(for: part, in: rows), groups: groups, friendly: true))
                }
            }
            if !essentials.isEmpty { views.append(EditorStyle.grid(essentials)) }
        }
        // "More": the rest, the repeated options (IfCondition2…), further live data of a graph (MeasureName2…).
        var more = visible.filter { $0.level != .essential }
        let full = groups.first { $0.title == group.title } ?? group
        for p in full.properties where p.numbered && !options.skip.contains(p.key.lowercased()) {
            let highest = rows.compactMap { EditorSchema.numberedProperty($0.key, in: [full])?.index }.max() ?? 1
            guard highest >= 2 else { continue }
            for i in 2...highest {
                let q = EditorSchema.numbered(p, index: i, in: groups)
                if EditorSchema.isVisible(q, in: groups, values: lookup) { more.append(q) }
            }
        }
        if group.properties.contains(where: { $0.key == "MeasureName" }), !group.properties.contains(where: { $0.key == "MeasureName2" }) {
            var i = 2
            while let extra = rows.first(where: { $0.key.caseInsensitiveCompare("MeasureName\(i)") == .orderedSame }) {
                more.append(EditorSchema.Property(extra.key, "Shows (\(i))", .sectionRef(.measure)))
                i += 1
            }
        }
        let inUse = more.filter { isInUse($0, rows: rows, groups: groups) }.count + options.extraMore.filter(\.inUse).count
        if !more.isEmpty || !options.extraMore.isEmpty {
            let open = isMoreOpen(group, section: section, inUse: inUse)
            views.append(moreRow(group, section: section, inUse: inUse, open: open))
            if open {
                var items: [InspectorRow] = options.extraMoreLast ? [] : options.extraMore.map(\.row)
                // Long lists of triggers: the ones in use and the usual ones; the rest one click away.
                let actions = more.filter { $0.kind == .action }
                let fold = actions.count > 6
                let foldKey = "\(section.lowercased())/\(group.title)/actions"
                let foldOpen = inspectorState.disclosures.contains(foldKey) || showsDetails
                let usual: Set<String> = ["mouseleaveaction", "rightmouseupaction", "leftmousedoubleclickaction",
                                          "mousescrollupaction", "mousescrolldownaction", "finishaction"]
                var folded = 0
                for p in more {
                    if fold, !foldOpen, p.kind == .action, row(for: p, in: rows) == nil, !usual.contains(p.key.lowercased()) {
                        folded += 1
                        continue
                    }
                    if let r = build(p, dot: isInUse(p, rows: rows, groups: groups)) { items.append(r) }
                }
                if fold, folded > 0 || foldOpen, !showsDetails {
                    let toggle = EditorStyle.disclosure(foldOpen ? "Fewer Triggers" : "Other Buttons and Scroll", open: foldOpen)
                    toggle.toolTip = foldOpen ? nil : "\(folded) more ways to trigger an action"
                    toggle.identifier = NSUserInterfaceItemIdentifier("more-actions")
                    toggle.onAction { [weak self] _ in
                        guard let self else { return }
                        if foldOpen { self.inspectorState.disclosures.remove(foldKey) } else { self.inspectorState.disclosures.insert(foldKey) }
                        self.rebuildKeepingScroll()
                    }
                    items.append(InspectorRow(label: nil, control: EditorStyle.hstack([toggle, EditorStyle.spacer()], spacing: 0)))
                }
                if options.extraMoreLast { items += options.extraMore.map(\.row) }
                if !items.isEmpty { views.append(EditorStyle.grid(items)) }
            }
        }
        views += options.bottom
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-\(title.isEmpty ? group.title : title)")
        return card
    }

    // MARK: - Position and Size

    /// The label of X or Y for a text: the point of the text it places ("X (right edge)" for right-aligned text).
    static func positionLabel(_ key: String, meter m: Meter) -> String {
        guard m.type.lowercased() == "string" else { return key }
        let (h, v) = alignParts(m.option("StringAlign") ?? "")
        if key == "X" { return ["X", "X (center)", "X (right edge)"][h] }
        return ["Y", "Y (middle)", "Y (bottom)"][v]
    }

    /// `StringAlign` as the engine reads it: horizontal (0 left, 1 center, 2 right) and vertical (0 top, 1 middle,
    /// 2 bottom).
    static func alignParts(_ raw: String) -> (h: Int, v: Int) {
        let value = EditorSchema.alignmentChoice(for: raw).value.lowercased()
        let h = value.hasPrefix("right") ? 2 : value.hasPrefix("center") ? 1 : 0
        let v = value.hasSuffix("bottom") ? 2 : value.count > 6 && value.hasSuffix("center") ? 1 : 0
        return (h, v)
    }

    /// `StringAlign` for a horizontal and vertical part ("Left" for left and top, "RightBottom").
    static func alignValue(h: Int, v: Int) -> String {
        ["Left", "Center", "Right"][h] + ["", "Center", "Bottom"][v]
    }

    /// A plain number as written (`12`, `-3.5`), nil for anything else.
    static func plainNumber(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ "0123456789.+-".unicodeScalars.contains($0) }) else { return nil }
        return Double(t.hasPrefix(".") ? "0" + t : t)
    }

    /// How a written position or size is linked to something else (docs/editor-friendly.md §7.3), as the grey tag
    /// after its number: "Left", "Left + 6", "calculated", "3 px after Bar 5", "Same top as “48 Hz”", "moves with peak
    /// level". nil for a plain number (or nothing written).
    func geometryLink(_ m: Meter, key: String, raw: String, skin: Skin) -> (title: String, kind: GeometryLinkKind)? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, OptionValue.number(t) == nil || LenientNumberFormatter.isExpression(t) || t.last == "r" || t.last == "R"
        else { return nil }
        if Self.plainNumber(t) != nil { return nil }
        // Relative to the layer before it (r: its X / Y; R: its right / bottom edge).
        if let last = t.last, last == "r" || last == "R" {
            t.removeLast()
            let offsetText = skin.resolve(t, in: skin.section(named: m.name), sectionVariables: true)
            let offset = t.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : (OptionValue.number(offsetText) ?? 0)
            guard let index = skin.meters.firstIndex(where: { $0 === m }), index > 0 else {
                return ("\(GeometryEdit.format(offset)) px from the start", .relative(nil))
            }
            let previous = skin.meters[index - 1]
            let name = displayName(ofSection: previous.name)
            let n = GeometryEdit.format(abs(offset))
            let title: String
            switch (key, last) {
            case ("X", "R"): title = offset == 0 ? "Right after \(name)" : offset > 0 ? "\(n) px after \(name)" : "Overlaps \(name) by \(n) px"
            case ("Y", "R"): title = offset == 0 ? "Right below \(name)" : offset > 0 ? "\(n) px below \(name)" : "Overlaps \(name) by \(n) px"
            case ("X", _): title = offset == 0 ? "Same left as \(name)" : "\(n) px \(offset > 0 ? "right" : "left") of \(name)"
            default: title = offset == 0 ? "Same top as \(name)" : "\(n) px \(offset > 0 ? "lower" : "higher") than \(name)"
            }
            return (title, .relative(previous.name))
        }
        // Moves with live data: [MeasurePeakX], or a formula using it.
        let refs = sectionReferences(in: t).compactMap { skin.measure(named: $0) }
        if let data = refs.first {
            return ("moves with \(Self.lowerFirst(dataName(data, in: skin)))", .data(data.name))
        }
        let variables = SkinInspection.referencedVariables(in: t)
        if let v = wholeVariable(t) {
            return (Self.sharedValueName(v), .variable(v))
        }
        // (#Left# + 6): the shared value, nudged.
        if variables.count == 1, t.hasPrefix("("), t.hasSuffix(")") {
            let inner = String(t.dropFirst().dropLast())
            let pattern = #"^\s*#([^#]+)#\s*([+-])\s*([0-9.]+)\s*$"#
            if let r = inner.range(of: pattern, options: .regularExpression) {
                let body = String(inner[r])
                let parts = body.replacingOccurrences(of: "#", with: " ").split(whereSeparator: { $0 == " " }).map(String.init)
                if parts.count == 3 { return ("\(Self.sharedValueName(parts[0])) \(parts[1]) \(parts[2])", .variableOffset(parts[0])) }
            }
        }
        return ("calculated", .formula(variables))
    }

    /// What a linked position is linked to.
    enum GeometryLinkKind: Equatable {
        case variable(String)
        case variableOffset(String)
        case formula([String])
        case relative(String?)
        case data(String)
    }

    /// `[Name]`, `[Name:X]` references in a value.
    func sectionReferences(in text: String) -> [String] {
        var result: [String] = []
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            let inner = text[text.index(after: open)..<close]
            let name = inner.split(separator: ":").first.map(String.init) ?? ""
            if !name.isEmpty, !name.hasPrefix("#"), !name.hasPrefix("!"), !name.hasPrefix("\\") { result.append(name) }
            i = text.index(after: close)
        }
        return result
    }

    /// Position and Size (docs/editor-friendly.md §8.2): X and Y as numbers in effect with their link tag, the size
    /// ("Fits the text · 38 × 16" or Width and Height), the six worded alignment buttons, and the nudge hint.
    func positionCard(_ m: Meter, skin: Skin) -> NSView {
        let raw = m.rawGeometry
        var items: [InspectorRow] = []
        items.append(geometryRow(m, key: "X", raw: raw.x ?? "", current: m.anchorX, skin: skin))
        items.append(geometryRow(m, key: "Y", raw: raw.y ?? "", current: m.anchorY, skin: skin))
        let fits = (raw.w ?? "").trimmingCharacters(in: .whitespaces).isEmpty && (raw.h ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let type = m.type.lowercased()
        let shapes = type == "shape" ? shapeItems(of: m.name) : []
        if fits, shapes.count == 1, let only = shapes.first, let spec = only.spec, spec.unknownType == nil, let rect = spec.rectangle {
            // One rectangle: its width and height are the layer's size.
            items.append(shapeSizeRow(m, item: only, index: 2, label: "Width", raw: rect.width,
                                      resolved: only.resolved?.rectangle?.width, skin: skin))
            items.append(shapeSizeRow(m, item: only, index: 3, label: "Height", raw: rect.height,
                                      resolved: only.resolved?.rectangle?.height, skin: skin))
        } else if fits, ["string", "image", "button", "bitmap", "rotator", "shape"].contains(type) {
            let what = type == "string" ? "the text" : type == "shape" ? "its shapes" : "the picture"
            let n = EditorStyle.number
            let label = EditorStyle.label("Fits \(what) · \(n(m.frame.width)) × \(n(m.frame.height))", size: 12, color: .secondaryLabelColor)
            label.identifier = NSUserInterfaceItemIdentifier("fits-size")
            let set = NSButton(title: "Set a Size…", target: nil, action: nil)
            set.bezelStyle = .rounded
            set.controlSize = .small
            set.identifier = NSUserInterfaceItemIdentifier("set-size")
            set.toolTip = "Give it a fixed width and height (now \(n(m.frame.width)) × \(n(m.frame.height)))"
            let name = m.name, w = m.frame.width, h = m.frame.height
            set.onAction { [weak self] _ in
                guard let self else { return }
                self.commitPlainly([Edit(section: name, key: "W", value: GeometryEdit.format(w), own: true),
                                    Edit(section: name, key: "H", value: GeometryEdit.format(h), own: true)],
                                   name: "Set Size of \(self.displayName(ofSection: name))",
                                   message: "\(self.displayName(ofSection: name)) is now \(n(w)) × \(n(h)) px")
            }
            items.append(InspectorRow(label: EditorStyle.rowLabel("Size", key: nil, tooltip: "Width and height"),
                                      control: EditorStyle.vstack([label, set], spacing: 4)))
        } else {
            items.append(geometryRow(m, key: "W", raw: raw.w ?? "", current: m.frame.width, skin: skin))
            items.append(geometryRow(m, key: "H", raw: raw.h ?? "", current: m.frame.height, skin: skin))
        }
        items.append(InspectorRow(label: nil, control: alignInWidget(), fullWidth: true))
        var views: [NSView] = [cardTitleRow("Position and Size", accessory: nil), EditorStyle.grid(items)]
        if pageState.selections <= 3 {
            let hint = cardNote("Drag it on the canvas, or nudge with the arrow keys (hold ⇧ for 10 px).")
            hint.identifier = NSUserInterfaceItemIdentifier("nudge-hint")
            views.append(hint)
        }
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-Position and Size")
        // Sizes and positions in effect change while the widget runs (a text's width with its value): the numbers
        // follow, unless a field is being edited.
        let name = m.name
        inspectorState.liveUpdates.append { [weak self, weak card] in
            guard let self, let card, let m = self.skin?.meter(named: name) else { return }
            let n = EditorStyle.number
            for (key, value) in [("X", m.anchorX), ("Y", m.anchorY), ("W", m.frame.width), ("H", m.frame.height)] {
                guard let field = card.findSubview(where: { $0.identifier?.rawValue == "\(name)/\(key)" }) as? ValueField,
                      field.currentEditor() == nil, !field.stringValue.isEmpty, field.stringValue == field.original else { continue }
                let text = GeometryEdit.format(value)
                if field.stringValue != text { field.stringValue = text; field.original = text }
            }
            if let fits = card.findSubview(where: { $0.identifier?.rawValue == "fits-size" }) as? NSTextField {
                let text = fits.stringValue.components(separatedBy: " · ").first.map { "\($0) · \(n(m.frame.width)) × \(n(m.frame.height))" }
                if let text, fits.stringValue != text { fits.stringValue = text }
            }
        }
        return card
    }

    /// Width or Height of a one-rectangle shape: the rectangle's own parameter, a link kept (`#Width#` →
    /// `(#Width# + 23)`).
    func shapeSizeRow(_ m: Meter, item: ShapeEditorView.ShapeItem, index: Int, label: String, raw: String, resolved: String?,
                      skin: Skin) -> InspectorRow {
        let current = OptionValue.number(resolved ?? raw) ?? 0
        let field = GeometryField(GeometryEdit.format(current))
        let id = "\(m.name)/\(item.key)/\(label)"
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let meter = m.name, key = item.key
        let written = raw.trimmingCharacters(in: .whitespaces)
        func write(_ value: Double) {
            let text = Self.plainNumber(written) != nil || written.isEmpty ? GeometryEdit.format(value)
                : GeometryEdit.offset(written, by: value - current)
            editShape(key, meter: meter) { spec in spec.setParam(index, text) }
        }
        field.validate = { Self.plainNumber($0) == nil ? "“\($0)” is not a number" : nil }
        field.onInvalid = { [weak self] problem in self?.toast.show(problem, error: true) }
        field.onCommit = { text in if let n = Self.plainNumber(text) { write(n) } }
        field.onStep = { delta in write(current + delta) }
        var parts: [NSView] = [field]
        if Self.plainNumber(written) == nil, !written.isEmpty {
            let title = wholeVariable(written).map(Self.sharedValueName) ?? "calculated"
            let tag = EditorStyle.label(title, size: 11, color: .secondaryLabelColor)
            tag.toolTip = showsDetails ? written : "Changing it keeps the calculation"
            tag.identifier = NSUserInterfaceItemIdentifier("\(id)/tag")
            parts.append(tag)
        } else {
            parts.append(EditorStyle.label("px", size: 11, color: .tertiaryLabelColor))
        }
        return InspectorRow(label: EditorStyle.rowLabel(label, key: nil, tooltip: "The shape's \(label.lowercased()) in px"),
                            control: EditorStyle.hstack(parts + [EditorStyle.spacer()], spacing: 6))
    }

    /// "Align in widget" (one layer) or "Line up" (several): six worded buttons in two rows.
    func alignInWidget(title: String = "Align in widget", several: Bool = false) -> NSView {
        let caption = EditorStyle.label(title, size: 11.5, color: .secondaryLabelColor)
        let modes: [[(EditorAlign.Mode, String, String)]] = several
            ? [[(.left, "Left Edges", "align.horizontal.left"), (.centerX, "Centers", "align.horizontal.center"),
                (.right, "Right Edges", "align.horizontal.right")],
               [(.top, "Tops", "align.vertical.top"), (.centerY, "Middles", "align.vertical.center"),
                (.bottom, "Bottoms", "align.vertical.bottom")]]
            : [[(.left, "Left", "align.horizontal.left"), (.centerX, "Center", "align.horizontal.center"),
                (.right, "Right", "align.horizontal.right")],
               [(.top, "Top", "align.vertical.top"), (.centerY, "Middle", "align.vertical.center"),
                (.bottom, "Bottom", "align.vertical.bottom")]]
        let rows: [NSView] = modes.map { line in
            let buttons: [NSView] = line.map { mode, word, symbol in
                let b = NSButton(title: word, image: EditorStyle.image(symbol, size: 11) ?? NSImage(), target: self,
                                 action: #selector(alignClicked(_:)))
                // Several: the words ("Left Edges") need the room.
                b.imagePosition = several ? .noImage : .imageLeading
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                b.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
                b.toolTip = Self.alignTitle(mode) + (several ? "" : " in the widget")
                b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return b
            }
            let row = EditorStyle.hstack(buttons, spacing: 4)
            row.distribution = .fillEqually
            return row
        }
        let stack = EditorStyle.vstack([caption] + rows, spacing: 4)
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.identifier = NSUserInterfaceItemIdentifier("align-buttons")
        return stack
    }

    /// One of X, Y, W, H: the number in effect (typing and the arrow keys keep a link: `GeometryEdit.offset`), and the
    /// grey tag of what it is linked to.
    /// `run`: the row is a group's "Starts at" (§8.4): a number typed or stepped moves every member of the run by
    /// the same amount (`moveRun`), and the tag offers nothing that would change the first member alone.
    func geometryRow(_ m: Meter, key: String, raw: String, current: Double, skin: Skin, run: [String]? = nil) -> InspectorRow {
        let names = ["X": Self.positionLabel("X", meter: m), "Y": Self.positionLabel("Y", meter: m), "W": "Width", "H": "Height"]
        let link = geometryLink(m, key: key, raw: raw, skin: skin)
        let id = "\(m.name)/\(key)"
        let editingShared = inspectorState.disclosures.contains("shared/\(id.lowercased())")
        var shared: String? {
            if case .variable(let v)? = link?.kind { return v }
            if case .variableOffset(let v)? = link?.kind { return v }
            return nil
        }
        let field: GeometryField
        if editingShared, let v = shared,
           let value = skin.inspectedVariables().first(where: { $0.name.caseInsensitiveCompare(v) == .orderedSame })?.raw {
            // "Change ‘Left’ for All 10 Layers…": the field edits the shared value itself.
            field = GeometryField(value)
            field.onCommit = { [weak self] text in
                guard let self else { return }
                self.inspectorState.disclosures.remove("shared/\(id.lowercased())")
                self.writeLinkedValue(v, value: text)
            }
            field.onCancel = { [weak self] in
                self?.inspectorState.disclosures.remove("shared/\(id.lowercased())")
                onNextTurn { self?.rebuildKeepingScroll() }
            }
            field.wantsLayer = true
            field.layer?.borderColor = NSColor.controlAccentColor.cgColor
            field.layer?.borderWidth = 2
            field.layer?.cornerRadius = 5
        } else if let run {
            field = GeometryField(GeometryEdit.format(current), placeholder: "0")
            field.onCommit = { [weak self] text in
                guard let self, !self.inspectorState.isRebuilding, let n = Self.plainNumber(text) else { return }
                self.moveRun(run, key: key, by: n - current)
            }
            field.onStep = { [weak self] delta in self?.moveRun(run, key: key, by: delta) }
        } else {
            let emptySize = (key == "W" || key == "H") && raw.trimmingCharacters(in: .whitespaces).isEmpty
            field = GeometryField(emptySize ? "" : GeometryEdit.format(current), placeholder: emptySize ? GeometryEdit.format(current) : "0")
            field.onCommit = { [weak self] text in self?.commitGeometryValue(m.name, key: key, typed: text) }
            field.onStep = { [weak self] delta in self?.stepGeometry(m.name, key: key, by: delta) }
        }
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.alignment = .right
        field.validate = run == nil || editingShared ? Self.geometryProblem
            : { Self.plainNumber($0) == nil ? "Type a number of px, like 36" : nil }
        field.onInvalid = { [weak self] problem in self?.toast.show(problem, error: true) }
        field.toolTip = key == "W" || key == "H" ? "In px; empty: it fits its content" : "In px from the widget's top-left corner"
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        var parts: [NSView] = [field]
        var below: NSView?
        if let link, !editingShared {
            let tag = geometryTag(m, key: key, raw: raw, current: current, link: link, skin: skin, run: run != nil)
            // A long tag ("3 px after Bar 5") gets its own line under the number rather than being cut off.
            if link.title.count > 11 { below = tag } else { parts.append(tag) }
        }
        if below != nil || link == nil || editingShared { parts.append(EditorStyle.label("px", size: 11, color: .tertiaryLabelColor)) }
        let line = EditorStyle.hstack(parts + [EditorStyle.spacer()], spacing: 6)
        var cellViews: [NSView] = [line]
        if let below { cellViews.append(below) }
        if editingShared, let v = shared {
            let users = layersUsing(variable: v, in: skin).count
            let caption = cardNote("Changing \(Self.sharedValueName(v)) for \(users) layer\(users == 1 ? "" : "s"). Return keeps it, Esc goes back.")
            caption.identifier = NSUserInterfaceItemIdentifier("shared-caption")
            cellViews.append(caption)
        }
        if inspectorState.disclosures.contains("calc/\(id.lowercased())") {
            let formula = ValueField(raw, placeholder: "Formula", monospaced: true)
            formula.identifier = NSUserInterfaceItemIdentifier("\(id)/formula")
            formula.onCommit = { [weak self] text in
                self?.inspectorState.disclosures.remove("calc/\(id.lowercased())")
                self?.commitGeometry(m.name, key: key, value: text)
            }
            formula.validate = Self.geometryProblem
            cellViews.append(formula)
            cellViews.append(cardNote("Math on other values. Numbers and names of shared sizes work here."))
        }
        let cell = EditorStyle.vstack(cellViews, spacing: 4)
        for v in cellViews { v.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor).isActive = true }
        line.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
        let label = EditorStyle.rowLabel(names[key] ?? key, key: showsDetails ? key : nil,
                                         tooltip: key == "W" || key == "H" ? "\(names[key] ?? key) in px" : "Position in px")
        return InspectorRow(label: label, control: cell)
    }

    /// The grey pull-down tag after a linked number (§7.3), with its menu.
    /// `run`: the tag of a group's "Starts at" — only what reads or selects, and the shared value's editor.
    func geometryTag(_ m: Meter, key: String, raw: String, current: Double,
                     link: (title: String, kind: GeometryLinkKind), skin: Skin, run: Bool = false) -> NSView {
        let tag = NSPopUpButton(frame: .zero, pullsDown: true)
        tag.isBordered = false
        tag.controlSize = .small
        tag.font = .systemFont(ofSize: 11)
        tag.contentTintColor = .secondaryLabelColor
        tag.identifier = NSUserInterfaceItemIdentifier("\(m.name)/\(key)/tag")
        tag.toolTip = (showsDetails ? "\(key)=\(raw)" : raw) + (link.kind == .formula([]) || {
            if case .formula = link.kind { return true } else { return false } }() ? "\nNudging keeps the calculation." : "")
        tag.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (tag.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: link.title, action: nil, keyEquivalent: "")
        menu.addItem(head)
        let name = m.name
        let fixed = GeometryEdit.format(current)
        let fixedTitle: String
        switch link.kind {
        case .relative, .data: fixedTitle = "Use a Fixed Position Here"
        default: fixedTitle = "Use a Fixed Number Here"
        }
        switch link.kind {
        case .variable(let v), .variableOffset(let v):
            let users = layersUsing(variable: v, in: skin)
            let id = "shared/\(name.lowercased())/\(key.lowercased())"
            menu.addItem(ClosureMenuItem(changeSharedTitle(v, users: "\(users.count) Layer\(users.count == 1 ? "" : "s")",
                                                           many: true)) { [weak self] in
                self?.inspectorState.disclosures.insert(id)
                self?.rebuildKeepingScroll()
                onNextTurn { [weak self] in
                    guard let self, let f = self.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "\(name)/\(key)" }) else { return }
                    self.window?.makeFirstResponder(f)
                }
            })
            if !run { menu.addItem(ClosureMenuItem(fixedTitle) { [weak self] in self?.commitGeometry(name, key: key, value: fixed) }) }
            menu.addItem(ClosureMenuItem("Highlight the \(users.count) Layer\(users.count == 1 ? "" : "s")") { [weak self] in
                self?.canvas.relatedNames = users
            })
        case .formula(let variables):
            if !run {
                menu.addItem(ClosureMenuItem(fixedTitle) { [weak self] in self?.commitGeometry(name, key: key, value: fixed) })
                menu.addItem(ClosureMenuItem("Show the Calculation…") { [weak self] in
                    self?.inspectorState.disclosures.insert("calc/\(name.lowercased())/\(key.lowercased())")
                    self?.rebuildKeepingScroll()
                })
            }
            let users = Array(Set(variables.flatMap { layersUsing(variable: $0, in: skin) })).sorted()
            menu.addItem(ClosureMenuItem("Highlight What It Depends On", enabled: !users.isEmpty) { [weak self] in
                self?.canvas.relatedNames = users
            })
        case .relative(let anchor):
            if !run { menu.addItem(ClosureMenuItem(fixedTitle) { [weak self] in self?.commitGeometry(name, key: key, value: fixed) }) }
            if let anchor {
                menu.addItem(ClosureMenuItem("Select \(displayName(ofSection: anchor))") { [weak self] in self?.select(section: anchor) })
            }
        case .data(let data):
            if !run { menu.addItem(ClosureMenuItem(fixedTitle) { [weak self] in self?.commitGeometry(name, key: key, value: fixed) }) }
            menu.addItem(ClosureMenuItem("Show the Live Data") { [weak self] in self?.select(section: data) })
        }
        tag.menu = menu
        tag.setTitle(link.title)
        tag.setAccessibilityLabel("\(key): \(link.title)")
        return tag
    }

    /// A number typed into X / Y / W / H: written keeping how it is linked (`#Left#` → `(#Left# + 6)`); other text
    /// (a formula, `10R`) is written as typed; an empty size is automatic again.
    func commitGeometryValue(_ meter: String, key: String, typed: String) {
        guard !inspectorState.isRebuilding, let skin, let m = skin.meter(named: meter) else { return }
        let t = typed.trimmingCharacters(in: .whitespaces)
        let raw: String? = { switch key { case "X": return m.rawGeometry.x; case "Y": return m.rawGeometry.y
                                          case "W": return m.rawGeometry.w; default: return m.rawGeometry.h } }()
        guard let number = Self.plainNumber(t) else {
            return commitGeometry(meter, key: key, value: t)
        }
        let current: Double = { switch key { case "X": return m.anchorX; case "Y": return m.anchorY
                                             case "W": return m.frame.width; default: return m.frame.height } }()
        let written = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let value = written.isEmpty || Self.plainNumber(written) != nil
            ? GeometryEdit.format(number) : GeometryEdit.offset(written, by: number - current)
        guard value != written else { return }
        let who = displayName(ofSection: meter)
        commitPlainly([Edit(section: meter, key: key, value: value, own: true)],
                      name: (key == "X" || key == "Y" ? "Move " : "Resize ") + who,
                      message: (key == "X" || key == "Y" ? "Moved " : "Resized ") + who)
    }

    /// ↑ / ↓ in a position field: one px (⇧: ten), keeping the link.
    func stepGeometry(_ meter: String, key: String, by delta: Double) {
        guard let skin, let m = skin.meter(named: meter) else { return }
        let raw: String? = { switch key { case "X": return m.rawGeometry.x; case "Y": return m.rawGeometry.y
                                          case "W": return m.rawGeometry.w; default: return m.rawGeometry.h } }()
        var written = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if written.isEmpty, key == "W" || key == "H" { written = GeometryEdit.format(key == "W" ? m.frame.width : m.frame.height) }
        let who = displayName(ofSection: meter)
        commitPlainly([Edit(section: meter, key: key, value: GeometryEdit.offset(written, by: delta), own: true)],
                      name: (key == "X" || key == "Y" ? "Nudge " : "Resize ") + who,
                      message: (key == "X" || key == "Y" ? "Moved " : "Resized ") + who)
    }
}

/// A position or size field: ↑ and ↓ step it (⇧ by ten) instead of moving the caret.
final class GeometryField: ValueField {
    var onStep: ((Double) -> Void)?

    init(_ value: String, placeholder: String = "") {
        super.init(value, placeholder: placeholder)
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if let onStep, commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)) {
            let up = commandSelector == #selector(NSResponder.moveUp(_:))
            onStep((up ? 1 : -1) * (shift ? 10 : 1))
            return true
        }
        return super.control(control, textView: textView, doCommandBy: commandSelector)
    }
}
