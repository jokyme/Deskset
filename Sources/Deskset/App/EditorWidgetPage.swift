import AppKit
import DesksetCore

/// The inspector's widget page: what it shows when nothing is selected — the widget itself (docs/editor-friendly.md
/// §8.1): a header with a picture of the widget and one sentence about it; COLORS AND FONTS (the widget's colors named
/// by what they do, with who uses them), UPDATE SPEED (presets that say what they mean), ON YOUR DESKTOP (the running
/// widget's own settings, applied at once), SIZE AND SPACING; then "Doesn't Work on a Mac", "About This Widget" and
/// "More Widget Options". Also the pages of the widget's own sections (`[Rainmeter]`, `[Variables]`, `[Metadata]`)
/// that the code's caret selects. The selection pages are in EditorInspector.swift.
///
/// Every change is one named undo step with a toast that says what it reached. Shared values are written for this
/// widget only unless "Apply to" says every widget (§8.1.1); the desktop settings are the running widget's
/// (`SkinState`), not the file's.
extension InspectorWindowController {
    // MARK: Nothing selected: the widget

    /// The page's cards are parts (`addPart`): when the editor opens, each is built in a step of its own.
    func skinOverview(_ skin: Skin) {
        let index = valueUsages(skin)
        addPart("header") { self.widgetHeader(skin) }
        if showsWidgetTip { addPart("tip") { self.widgetTipLine() } }
        addCard("colors and fonts") { self.colorsAndFontsCard(skin, index: index) }
        addPart("update speed") { self.updateSpeedCard(skin) }
        addPart("desktop") { self.desktopCard() }
        addCard("size and spacing") { self.sizeAndSpacingCard(skin, index: index) }
        if !skin.missingIncludeFiles.isEmpty || !skin.missingLooks.isEmpty { addPart("missing") { self.missingDisclosure(skin) } }
        if !skin.issues.isEmpty { addPart("issues") { self.issuesDisclosure(skin) } }
        addPart("about") { self.aboutDisclosure(skin) }
        addPart("more options") { self.moreWidgetOptions(skin, index: index) }
        if app.state.editor.showIniNames {
            let covered = EditorSchema.keys(EditorSchema.skinGroups)
            let rows = self.rows(of: "Rainmeter", kind: .rainmeter)
            if rows.contains(where: { !covered.contains($0.key.lowercased()) }) {
                addPart("other lines") {
                    self.otherOptionsCard(section: "Rainmeter", rows: rows, groups: EditorSchema.skinGroups, open: true,
                                          title: "Lines Deskset Can't Show as Controls")
                }
            }
        }
    }

    /// What the widget page is built from beyond the widget's own sections (for `inspectorInputs`): the desktop
    /// settings, who uses each shared value, the fonts, the page's own choices.
    func widgetPageInputs() -> [String] {
        guard let skin else { return [] }
        var lines: [String] = []
        if let c = controller { lines.append("desktop \(isWidgetRunning) \(Self.desktopSettings(c.state))") }
        lines.append("page \(appliesToAllWidgets) \(inspectorState.separateColors.sorted()) \(showsWidgetTip)")
        for v in valueUsages(skin).values {
            lines.append("value \(v.source) \(v.current) \(v.sections.joined(separator: ",")) \(v.roles.map(\.name))")
        }
        for f in fontSources(skin) {
            lines.append("font \(f.title) \(f.face.raw) \(f.face.current) \(f.size?.raw ?? "") \(f.size?.current ?? "")")
        }
        return lines
    }

    // MARK: Header

    func widgetHeader(_ skin: Skin) -> NSView {
        let name = ManageModel.metadataValue(skin.metadata, "Name") ?? String(skin.config.split(separator: "\\").last ?? "")
        let picture = NSImageView(image: widgetThumbnail(skin, side: 48))
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 9
        picture.layer?.cornerCurve = .continuous
        picture.layer?.borderWidth = 0.5
        picture.layer?.borderColor = NSColor.separatorColor.cgColor
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.widthAnchor.constraint(equalToConstant: 48).isActive = true
        picture.heightAnchor.constraint(equalToConstant: 48).isActive = true
        picture.setAccessibilityLabel("Picture of the widget")

        let title = EditorStyle.label(name.isEmpty ? skin.config : name, size: 17, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier("widget-title")
        let layers = skin.meters.count
        let speed = WidgetPresets.updateWords(for: Int(skin.rainmeterSection?.rawOption("Update").flatMap(OptionValue.number) ?? 1000))
        let lead = "A widget with \(layers) layer\(layers == 1 ? "" : "s") that "
        let sentence = NSMutableAttributedString(string: lead, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        sentence.append(NSAttributedString(string: "updates \(speed)", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor,
        ]))
        sentence.append(NSAttributedString(string: ".", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let about = NSTextField(wrappingLabelWithString: "")
        about.attributedStringValue = sentence
        about.isSelectable = false
        about.maximumNumberOfLines = 3
        about.identifier = NSUserInterfaceItemIdentifier("widget-sentence")
        about.toolTip = "Change how often it updates"
        about.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showUpdateSpeedCard)))
        headerSubtitle = nil

        let n = EditorStyle.number
        let size = EditorStyle.label("\(n(skin.width)) × \(n(skin.height)) px", size: 11.5, color: .tertiaryLabelColor)
        size.identifier = NSUserInterfaceItemIdentifier("widget-size")
        inspectorState.liveUpdates.append { [weak self, weak size] in
            guard let self, let skin = self.skin else { return }
            size?.stringValue = "\(n(skin.width)) × \(n(skin.height)) px"
        }
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.isBordered = false
        more.bezelStyle = .inline
        let menu = NSMenu()
        menu.autoenablesItems = false
        let icon = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        icon.image = EditorStyle.image("ellipsis.circle", size: 14)
        menu.addItem(icon)
        let location = skin.sources.location(section: "Rainmeter") ?? IniSourceLocation(file: skin.fileURL, line: 1)
        menu.addItem(ClosureMenuItem("Show in Code") { [weak self] in self?.showInCode(location) })
        menu.addItem(ClosureMenuItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skin.fileURL]) })
        menu.addItem(ClosureMenuItem("Show in Manage Widgets") { [weak self] in
            guard let self else { return }
            self.app.showManageWindow(selecting: self.config, file: self.controller?.file)
        })
        menu.addItem(ClosureMenuItem("Reload Widget") { [weak self] in self?.refreshClicked() })
        more.menu = menu
        more.toolTip = "More"
        more.setAccessibilityLabel("More")
        more.identifier = NSUserInterfaceItemIdentifier("widget-more")
        let sizeLine = EditorStyle.hstack([size, EditorStyle.spacer(), more], spacing: 6)
        var texts: [NSView] = [title, about, sizeLine]
        if app.state.editor.showIniNames {
            let source = NSButton(title: "[Rainmeter] · \(location.file.lastPathComponent):\(location.line)", target: self,
                                  action: #selector(openInEditor))
            source.isBordered = false
            source.font = .systemFont(ofSize: 11)
            source.contentTintColor = .controlAccentColor
            source.image = EditorStyle.image("arrow.up.forward", size: 9, weight: .semibold)
            source.imagePosition = .imageTrailing
            texts.append(source)
        }
        let column = EditorStyle.vstack(texts, spacing: 3)
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for v in [about, sizeLine] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        about.preferredMaxLayoutWidth = EditorStyle.inspectorWidth - 32 - 60
        let row = EditorStyle.hstack([picture, column], spacing: 12, alignment: .top)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 4, right: 0)
        // The picture is shorter than the words beside it.
        EditorStyle.holdVerticalInsets(row)
        row.identifier = NSUserInterfaceItemIdentifier("widget-header")
        return row
    }

    @objc func showUpdateSpeedCard() { scrollInspector(toCard: "UPDATE SPEED") }

    // Scrolling to a card (the header's link, `--scroll`): `scrollInspector(toCard:)` in InspectorWindowController.

    /// A picture of the widget as it is now, fitted into a square.
    func widgetThumbnail(_ skin: Skin, side: CGFloat) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard skin.width > 0, skin.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return EditorStyle.image("rectangle.on.rectangle", size: 22) ?? NSImage()
        }
        rep.size = NSSize(width: side, height: side)
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let inset: CGFloat = 4
        let fit = min((side - 2 * inset) / CGFloat(skin.width), (side - 2 * inset) / CGFloat(skin.height))
        let w = CGFloat(skin.width) * fit, h = CGFloat(skin.height) * fit
        cg.translateBy(x: 0, y: CGFloat(pixels))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: (side - w) / 2, y: (side - h) / 2)
        cg.scaleBy(x: fit, y: fit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        SkinRenderer.draw(skin, in: cg)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Tip T1 as the page's top line (§12): the first time the editor opens, never in self-tests or snapshots.
    var showsWidgetTip: Bool { app.presentsWindows && !app.state.editor.seenTips.contains("T1") }

    func widgetTipLine() -> NSView {
        let text = EditorStyle.label("Click anything in your widget to change it. Drag new things in from Add.", size: 11.5,
                                     color: .secondaryLabelColor)
        text.maximumNumberOfLines = 3
        text.cell?.wraps = true
        text.lineBreakMode = .byWordWrapping
        let close = NSButton(image: EditorStyle.image("xmark", size: 9, weight: .bold) ?? NSImage(), target: nil, action: nil)
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Don't show this again"
        close.onAction { [weak self] _ in
            self?.app.state.updateEditor { $0.seenTips.insert("T1") }
            self?.rebuildKeepingScroll()
        }
        let row = EditorStyle.hstack([text, close], spacing: 8, alignment: .top)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 8)
        EditorStyle.holdVerticalInsets(row)
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        row.identifier = NSUserInterfaceItemIdentifier("widget-tip")
        return row
    }

    // MARK: Building blocks

    /// A card of the widget page, found by its title (`card:TITLE`).
    func pageCard(_ title: String, note: String? = nil, views: [NSView]) -> EditorCard {
        var all = views
        if let note { all.insert(cardNote(note), at: 0) }
        let card = EditorCard(title: title, views: all)
        card.identifier = NSUserInterfaceItemIdentifier("card:\(title.uppercased())")
        return card
    }

    /// A caption under a control (11 pt, wrapping).
    func caption(_ text: String, color: NSColor = .secondaryLabelColor, identifier: String? = nil) -> NSTextField {
        let l = EditorStyle.label(text, size: 11, color: color)
        l.maximumNumberOfLines = 4
        l.cell?.wraps = true
        l.lineBreakMode = .byWordWrapping
        if let identifier { l.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return l
    }

    /// A row label in the page's words (with Rainmeter Details, the option name under it).
    func pageLabel(_ text: String, key: String?, tooltip: String? = nil) -> NSView {
        EditorStyle.rowLabel(text, key: app.state.editor.showIniNames ? key : nil, tooltip: tooltip ?? text)
    }

    /// A label above the control it names — the widget page's cards put every label there, so a card reads down one
    /// column (with Rainmeter Details, the option name after it).
    func stackedLabel(_ text: String, key: String?, identifier: String? = nil) -> NSView {
        let label = EditorStyle.label(text, size: 11.5, color: .secondaryLabelColor)
        label.toolTip = text
        if let identifier { label.identifier = NSUserInterfaceItemIdentifier(identifier) }
        guard app.state.editor.showIniNames, let key else { return label }
        let name = EditorStyle.mono(key, size: 9.5, color: .tertiaryLabelColor)
        // Where both don't fit (legacy scroll bars), the option name is shortened, not the words (at one priority,
        // either could be).
        label.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        return EditorStyle.hstack([label, name, EditorStyle.spacer()], spacing: 6, alignment: .firstBaseline)
    }

    /// Whether a disclosure of the page is open: always with Rainmeter Details; else as the user left it, else
    /// `automatic` (it opens by itself when something in it is in use).
    func isDisclosureOpen(_ id: String, automatic: Bool = false) -> Bool {
        if app.state.editor.showIniNames { return true }
        if inspectorState.disclosures.contains(id) { return true }
        if inspectorState.disclosures.contains(id + ":closed") { return false }
        return automatic
    }

    func toggleDisclosure(_ id: String, automatic: Bool) {
        let open = isDisclosureOpen(id, automatic: automatic)
        inspectorState.disclosures.remove(id)
        inspectorState.disclosures.remove(id + ":closed")
        inspectorState.disclosures.insert(open ? id + ":closed" : id)
        rebuildKeepingScroll()
    }

    /// "▸ More Desktop Options   snapping, keep on screen, fade · 1 in use".
    func disclosureHeader(_ title: String, id: String, summary: String, inUse: Int = 0, open: Bool,
                          automatic: Bool = false) -> NSView {
        let button = EditorStyle.disclosure(title, open: open)
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .labelColor
        button.identifier = NSUserInterfaceItemIdentifier("disclosure:\(id)")
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.onAction { [weak self] _ in self?.toggleDisclosure(id, automatic: automatic) }
        // Lines break only between the listed items, never inside one ("when pointed at", "· 1 in use").
        let nbsp = "\u{00A0}"
        var text = summary.components(separatedBy: ", ").map { $0.replacingOccurrences(of: " ", with: nbsp) }
            .joined(separator: ", ")
        if inUse > 0 { text += (text.isEmpty ? "" : " ·" + nbsp) + "\(inUse)\(nbsp)in\(nbsp)use" }
        let line = EditorStyle.hstack([button, EditorStyle.spacer()], spacing: 0)
        guard !text.isEmpty else { return line }
        // What it holds, under its title (it wraps rather than hiding "· 1 in use").
        let detail = caption(text, color: .tertiaryLabelColor, identifier: "disclosure-summary:\(id)")
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let under = EditorStyle.hstack([indent, detail], spacing: 0, alignment: .top)
        let stack = EditorStyle.vstack([line, under], spacing: 1)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        under.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setAccessibilityLabel(title)
        return stack
    }

    /// A disclosure of the page, drawn as a card (its header only while closed).
    func disclosureCard(_ id: String, views: [NSView]) -> NSView {
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card:\(id)")
        return card
    }

    /// A borderless accent-colored button ("Select It", "Edit Calculation…").
    func pageLink(_ title: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 11.5, weight: .medium)
        b.contentTintColor = .controlAccentColor
        return b
    }

    /// A link-like count ("18 bars") that selects the layers it counts.
    func countLink(_ title: String, layers: [String], identifier: String) -> NSButton {
        let count = NSButton(title: title, target: nil, action: nil)
        count.isBordered = false
        count.font = .systemFont(ofSize: 11.5)
        count.contentTintColor = .controlAccentColor
        count.lineBreakMode = .byTruncatingTail
        count.setContentCompressionResistancePriority(.defaultLow + 2, for: .horizontal)
        count.identifier = NSUserInterfaceItemIdentifier(identifier)
        count.toolTip = layers.isEmpty ? nil : "Select them"
        count.isEnabled = !layers.isEmpty
        count.onAction { [weak self] _ in self?.selectLayers(layers) }
        return count
    }

    /// The width of a card's content in the narrowest inspector (legacy scrollers): the widget page's rows are laid
    /// out for it, so nothing is cut off at any width of the inspector.
    static var pageRowWidth: CGFloat { EditorStyle.minimumControlWidth + EditorStyle.labelColumnWidth + 10 }

    /// The first line of a widget-page row — `[lead] name   [trailing] count` — with the name kept whole (G1): the
    /// count moves under the name when both don't fit on one line in the narrowest inspector, and a name still too
    /// long wraps to a second line. `moved` says whether the caller puts the count under the name.
    func nameLine(lead: NSView?, leadWidth: CGFloat = 0, name: NSTextField, trailing: [NSView], count: NSView?)
        -> (line: NSStackView, moved: Bool) {
        let spacing: CGFloat = 6
        let width = Self.pageRowWidth
        let fixed = (lead == nil ? 0 : leadWidth + spacing) + trailing.reduce(0) { $0 + $1.fittingSize.width + spacing }
        let countWidth = count.map { $0.fittingSize.width + spacing } ?? 0
        // Lead, name, spacer (two gaps around it, no width), the trailing views, the count.
        let fits = fixed + name.fittingSize.width + spacing + countWidth <= width
        let room = width - fixed - spacing - (fits ? countWidth : 0)
        name.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        if name.fittingSize.width > room {
            name.cell?.wraps = true
            name.lineBreakMode = .byWordWrapping
            name.cell?.truncatesLastVisibleLine = true
            name.maximumNumberOfLines = 2
            name.preferredMaxLayoutWidth = floor(room)
        }
        var views: [NSView] = lead.map { [$0] } ?? []
        views += [name, EditorStyle.spacer()] + trailing
        if fits, let count { views.append(count) }
        let line = EditorStyle.hstack(views, spacing: spacing, alignment: name.maximumNumberOfLines > 1 ? .top : .centerY)
        return (line, !fits && count != nil)
    }

    /// Lines under a row's name, indented to it (`indent`: where the name starts).
    func underName(_ views: [NSView], indent: CGFloat) -> NSStackView {
        let stack = EditorStyle.vstack(views, spacing: 2)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return stack
    }

    /// Selects layers (the canvas and the inspector follow).
    func selectLayers(_ names: [String]) {
        guard !names.isEmpty else { return }
        canvas.setSelection(names: names)
        canvasSelectionChanged(names)
    }

    // MARK: Colors and fonts (§8.1.1)

    /// The card with its first rows, and the makers of its other rows (added one by one: `addCard`).
    func colorsAndFontsCard(_ skin: Skin, index: ValueUsageIndex) -> (card: EditorCard, rows: [() -> NSView]) {
        let expert = app.state.editor.showIniNames
        let groups = index.colorGroups(separate: inspectorState.separateColors, includeInternal: expert)
        var views: [NSView] = []
        // "Apply to" decides for every value of the page defined in a file other widgets share: the colors and fonts
        // here, the shared sizes, the other shared values.
        let fonts = fontSources(skin)
        let colorFiles = groups.compactMap(\.sharedFile)
        let fontFiles = fonts.compactMap { fontFile($0.face) }.filter { !skin.isOwnFile($0) }
        let valueFiles = index.values.compactMap { v -> URL? in
            guard v.kind == .size || v.kind == .other, !v.uses.isEmpty, case .shared(let url) = v.origin else { return nil }
            return url
        }
        if !(colorFiles + fontFiles + valueFiles).isEmpty {
            views.append(contentsOf: applyToBlock(colors: colorFiles, fonts: fontFiles, others: valueFiles, skin: skin))
        }
        var rows: [() -> NSView] = []
        let open = isDisclosureOpen("widget/colors-more")
        for (i, group) in groups.enumerated() where i < 6 || open {
            rows.append { self.colorRow(group, index: i) }
        }
        if groups.count > 6 {
            rows.append {
                let hidden = groups.count - 6
                let more = EditorStyle.disclosure(open ? "Show Fewer Colors" : "Show \(hidden) More Color\(hidden == 1 ? "" : "s")",
                                                  open: open)
                more.identifier = NSUserInterfaceItemIdentifier("disclosure:widget/colors-more")
                more.onAction { [weak self] _ in self?.toggleDisclosure("widget/colors-more", automatic: false) }
                return EditorStyle.hstack([more, EditorStyle.spacer()], spacing: 0)
            }
        }
        if groups.isEmpty {
            rows.append { self.caption("This widget doesn't use any colors yet.", color: .tertiaryLabelColor) }
        }
        for font in fonts { rows.append { self.fontRow(font) } }
        // The card comes with its first two rows; the others follow it.
        views += rows.prefix(2).map { $0() }
        let card = pageCard("Colors and Fonts", note: "Change one and everything that uses it follows. Point at one to see where.",
                            views: views)
        return (card, Array(rows.dropFirst(2)))
    }

    /// "ⓘ These colors come from the Deskset theme, shared by 6 widgets." and "Apply to [This Widget | All 6 Widgets]"
    /// with what each choice reaches (§8.1.1). A theme is a file a variable chooses (`Skin.switchedInclude`): its
    /// looks are named; a file every widget always reads (Variables.inc) is not one.
    func applyToBlock(colors: [URL], fonts: [URL], others: [URL], skin: Skin) -> [NSView] {
        var files: [URL] = []
        for f in colors + fonts + others where !files.contains(f) { files.append(f) }
        let count = max(files.map { configsIncluding($0).count }.max() ?? 1, 1)
        let root = skin.rootConfig
        var themes: [Skin.SwitchedInclude] = []
        for f in files { if let t = theme(f), !themes.contains(t) { themes.append(t) } }
        let colorsFromTheme = !colors.isEmpty && colors.allSatisfy { theme($0) != nil }
        let what = colors.isEmpty ? nil : fonts.isEmpty ? "These colors" : "These colors and fonts"
        let widgets = "\(count) widget\(count == 1 ? "" : "s")"
        let noteText: String
        if let what, colorsFromTheme {
            noteText = "\(what) come from the \(root) theme, shared by \(widgets)."
        } else if let what {
            noteText = "\(what) are shared by \(count) \(root) widget\(count == 1 ? "" : "s")."
        } else {
            noteText = "Some of this widget's settings are shared by \(count) \(root) widget\(count == 1 ? "" : "s")."
        }
        let icon = NSImageView(image: EditorStyle.image("info.circle", size: 11) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let note = caption(noteText, identifier: "shared-colors-note")
        let info = EditorStyle.hstack([icon, note], spacing: 5, alignment: .top)
        let seg = NSSegmentedControl(labels: ["This Widget", "All \(count) Widgets"], trackingMode: .selectOne, target: nil,
                                     action: nil)
        seg.controlSize = .small
        seg.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        seg.selectedSegment = appliesToAllWidgets ? 1 : 0
        seg.identifier = NSUserInterfaceItemIdentifier("apply-to")
        seg.setAccessibilityLabel("Apply to")
        seg.onAction { [weak self] c in
            guard let self, let s = c as? NSSegmentedControl else { return }
            self.appliesToAllWidgets = s.selectedSegment == 1
            self.rebuildKeepingScroll()
        }
        let name = ManageModel.metadataValue(skin.metadata, "Name") ?? String(skin.config.split(separator: "\\").last ?? "")
        let text: String
        if appliesToAllWidgets {
            // Only the look in use changes: the theme file of the other look keeps its values.
            let looks = themes.map(\.name).joined(separator: " and ")
            if themes.isEmpty {
                text = "Changes every \(root) widget."
            } else if colorsFromTheme && Set(files).count == themes.count {
                text = "Changes every \(root) widget, in the \(looks) look only."
            } else {
                text = "Changes every \(root) widget; theme colors in the \(looks) look only."
            }
        } else {
            let others = themes.flatMap(\.others)
            text = "Only \(name) changes." + (others.isEmpty ? "" : " Also used when you switch to the \(others.joined(separator: " or ")) look.")
        }
        let label = EditorStyle.label("Apply to", size: 11.5, color: .secondaryLabelColor)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = EditorStyle.hstack([label, seg, EditorStyle.spacer()], spacing: 8)
        return [info, line, caption(text, color: .tertiaryLabelColor, identifier: "apply-to-caption")]
    }

    /// One color of the widget (§8.1.1): `[■] Bar color   11%   18 bars`, what else it changes under it. Pointing at
    /// it outlines who uses it; the count selects them; the swatch opens its menu (Custom Color…). `otherWidgets`: a
    /// color only other widgets use (More Widget Options), changed for all of them.
    func colorRow(_ group: ValueUsageIndex.ColorGroup, index: Int, otherWidgets: Bool = false) -> ValueRowView {
        let expert = app.state.editor.showIniNames
        let row = ValueRowView()
        row.identifier = NSUserInterfaceItemIdentifier("color-row:\(index)")
        row.group = group
        let swatch = SwatchButton()
        swatch.color = group.color
        swatch.backdrop = widgetPanelColor()
        swatch.cornerRadius = 5
        swatch.removeConstraints(swatch.constraints)
        swatch.widthAnchor.constraint(equalToConstant: 24).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
        swatch.identifier = NSUserInterfaceItemIdentifier("color-swatch:\(index)")
        let variables = group.variables
        let tip = expert
            ? (variables.isEmpty ? "Written directly" : variables.joined(separator: ", ")) + " · " + (group.members.first?.current ?? "")
            : "\(Self.hex(group.color)) · \(Int((group.color.a / 255 * 100).rounded()))% opacity"
        swatch.toolTip = tip
        let name = EditorStyle.label(group.name, size: 12.5)
        name.toolTip = tip
        name.identifier = NSUserInterfaceItemIdentifier("color-name:\(index)")
        var trailing: [NSView] = []
        if group.color.a < 254.5 {
            let opacity = EditorStyle.label("\(Int((group.color.a / 255 * 100).rounded()))%", size: 11, color: .secondaryLabelColor)
            opacity.setContentCompressionResistancePriority(.required, for: .horizontal)
            opacity.identifier = NSUserInterfaceItemIdentifier("color-opacity:\(index)")
            trailing.append(opacity)
        }
        let meters = layersReached(group.sections)
        // A color only other widgets use has no count here: the note above the rows says so.
        let count = otherWidgets ? nil : countLink(usersPhrase(group.sections, atLeast: group.isAtLeast), layers: meters,
                                                   identifier: "color-count:\(index)")
        swatch.onAction { [weak self, weak swatch] _ in
            guard let self, let swatch else { return }
            self.colorRowMenu(group, otherWidgets: otherWidgets).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: swatch)
        }
        let (line, moved) = nameLine(lead: swatch, leadWidth: 24, name: name, trailing: trailing, count: count)
        var under: [NSView] = moved ? [count].compactMap { $0 } : []
        // What else the row changes: the roles of this widget's uses; same-value colors only other widgets use are
        // counted, not named (their names would be other widgets' words).
        let unused = group.unusedCount
        let roles = group.usedRoles.map(\.name)
        let others = unused == 0 ? "" : "\(roles.isEmpty ? "" : ", and ")\(unused) that other widgets use"
        if variables.count > 1 {
            under.append(caption("Changes \(variables.count) shared colors — " + roles.joined(separator: ", ") + others,
                                 color: .tertiaryLabelColor, identifier: "color-caption:\(index)"))
        } else if roles.count > 1 {
            under.append(caption(roles.joined(separator: ", "), color: .tertiaryLabelColor, identifier: "color-caption:\(index)"))
        }
        if expert, !variables.isEmpty {
            let names = EditorStyle.mono(variables.joined(separator: " · "), size: 10)
            names.identifier = NSUserInterfaceItemIdentifier("color-variables:\(index)")
            under.append(names)
        }
        var lines: [NSView] = [line]
        if !under.isEmpty { lines.append(underName(under, indent: 30)) }
        let content = EditorStyle.vstack(lines, spacing: 2)
        row.install(content)
        for l in lines { l.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        row.onHover = { [weak self] inside in self?.canvas.relatedNames = inside ? meters : [] }
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(group.name), used by \(otherWidgets ? "other widgets" : usersPhrase(group.sections))")
        return row
    }

    /// A color row's menu: Custom Color…, Copy Color Code, Select them, Show Separately / Show Together.
    func colorRowMenu(_ group: ValueUsageIndex.ColorGroup, otherWidgets: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let reach = otherWidgets ? "other widgets" : usersPhrase(group.sections, atLeast: group.isAtLeast)
        let header = NSMenuItem(title: "\(group.name) · \(reach)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Custom Color…") { [weak self] in self?.editColorRow(group, everywhere: otherWidgets) })
        let hex = Self.hex(group.color)
        menu.addItem(ClosureMenuItem("Copy Color Code  (\(hex))") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
        })
        let meters = layersReached(group.sections)
        if meters.count > 1 {
            menu.addItem(ClosureMenuItem("Select the \(Self.titleCase(usersPhrase(group.sections)))") { [weak self] in
                self?.selectLayers(meters)
            })
        }
        // A color this widget gave itself over a shared one (an earlier "This Widget" edit): back to the shared one.
        if let skin {
            let overridden = group.variables.filter { v in
                skin.sources.location(section: "Variables", key: v).map { skin.isOwnFile($0.file) } == true
                    && skin.sharedDefinition(ofVariable: v) != nil
            }
            if !overridden.isEmpty {
                let item = ClosureMenuItem("Use the Theme's Color") { [weak self] in
                    guard let self, let skin = self.skin else { return }
                    let writes = overridden.compactMap { v in
                        skin.sources.location(section: "Variables", key: v).map {
                            KeyWrite(file: $0.file, section: "Variables", key: v, value: nil)
                        }
                    }
                    self.writeKeys(writes, name: "Use the Theme's Color",
                                   message: "\(Self.capitalizedFirst(group.name)) follows the theme again")
                }
                item.identifier = NSUserInterfaceItemIdentifier("use-theme-color")
                menu.addItem(item)
            }
        }
        let variables = group.variables
        if variables.count > 1 {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show Separately") { [weak self] in
                guard let self else { return }
                for v in variables { self.inspectorState.separateColors.insert(v.lowercased()) }
                self.rebuildKeepingScroll()
            })
        } else if let v = variables.first, inspectorState.separateColors.contains(v.lowercased()) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show Together") { [weak self] in
                guard let self, let skin = self.skin else { return }
                let key = ValueUsageIndex.colorKey(group.color)
                for value in valueUsages(skin).values where value.color.map(ValueUsageIndex.colorKey) == key {
                    if let name = value.variableName { self.inspectorState.separateColors.remove(name.lowercased()) }
                }
                self.rebuildKeepingScroll()
            })
        }
        return menu
    }

    /// Opens the color panel on a row: its shared colors (all of them), or its literal color everywhere it is written.
    /// `everywhere`: written for every widget sharing them, whatever "Apply to" says.
    func editColorRow(_ group: ValueUsageIndex.ColorGroup, everywhere: Bool = false) {
        let variables = group.variables
        let target: ColorEdit.Target = variables.isEmpty
            ? .literal(group.color, role: group.name, users: group.sections)
            : .variables(variables, role: group.name, users: group.sections)
        var edit = ColorEdit(target: target)
        edit.everywhere = everywhere
        startColorEdit(edit, current: group.color)
    }

    /// Where the widget's text gets its font (§8.1.1 "Fonts"): a shared value, a look, or one layer's own options.
    struct FontSource {
        struct Place: Equatable {
            enum Kind: Equatable { case variable, look, layer }

            /// The variable, the look or the layer that writes it.
            var owner: String
            var kind: Kind
            var key: String
            var raw: String
            var current: String
        }

        var title: String
        var face: Place
        /// Where the size is written, when every layer of the row takes it from the same place.
        var size: Place?
        var users: [String]
    }

    /// One row per place a text's font comes from, in the order the layers are drawn.
    func fontSources(_ skin: Skin) -> [FontSource] {
        let texts = skin.meters.filter { $0.type == "string" }
        func place(_ m: Meter, _ key: String) -> FontSource.Place? {
            guard let raw = m.fileOption(key), !raw.isEmpty else { return nil }
            let current = skin.resolve(raw, in: m, sectionVariables: false)
            if let v = wholeVariable(raw) { return .init(owner: v, kind: .variable, key: key, raw: raw, current: current) }
            if case .style(let look, _)? = m.fileOrigin(key) {
                return .init(owner: look, kind: .look, key: key, raw: raw, current: current)
            }
            return .init(owner: m.name, kind: .layer, key: key, raw: raw, current: current)
        }
        var order: [String] = []
        var byOwner: [String: (face: FontSource.Place, users: [Meter])] = [:]
        for m in texts {
            guard let face = place(m, "FontFace") else { continue }
            let id = "\(face.kind)|\(face.owner.lowercased())"
            if byOwner[id] == nil { order.append(id); byOwner[id] = (face, []) }
            byOwner[id]?.users.append(m)
        }
        func textWords(_ m: Meter) -> String {
            ValueUsageIndex.textRole(ValueUsageIndex.layerWords(m, title: displayName(ofSection: m.name)))
        }
        return order.compactMap { id in
            guard let entry = byOwner[id] else { return nil }
            let sizes = entry.users.map { place($0, "FontSize") }
            let size: FontSource.Place? = sizes.first.flatMap { first in sizes.allSatisfy { $0 == first } ? first : nil } ?? nil
            let title: String
            if entry.users.count == texts.count && texts.count > 1 {
                title = "All text"
            } else {
                switch entry.face.kind {
                case .look:
                    title = ValueUsageIndex.textRole(ValueUsageIndex.humanizedLook(entry.face.owner))
                case .layer:
                    title = textWords(entry.users[0])
                case .variable:
                    if let look = entry.users.lazy.compactMap({ m -> String? in
                        if case .style(let l, _)? = m.fileOrigin("FontFace") { return l }
                        return nil
                    }).first {
                        title = ValueUsageIndex.textRole(ValueUsageIndex.humanizedLook(look))
                    } else if entry.users.count == 1 {
                        title = textWords(entry.users[0])
                    } else {
                        title = ValueUsageIndex.humanizedVariable(entry.face.owner)
                    }
                }
            }
            return FontSource(title: title, face: entry.face, size: size, users: entry.users.map(\.name))
        }
    }

    /// `Title text   “Audio”` over `[Helvetica Neue ▾] [11] pt`.
    func fontRow(_ font: FontSource) -> ValueRowView {
        let row = ValueRowView()
        row.identifier = NSUserInterfaceItemIdentifier("font-row:\(font.title)")
        let name = EditorStyle.label(font.title, size: 12.5)
        name.identifier = NSUserInterfaceItemIdentifier("font-name:\(font.title)")
        if app.state.editor.showIniNames { name.toolTip = "\(font.face.owner) · \(font.face.raw)" }
        let meters = font.users
        let count = countLink(usersPhrase(meters), layers: meters, identifier: "font-count:\(font.title)")
        let (top, moved) = nameLine(lead: nil, name: name, trailing: [], count: count)
        let popup = fontPopup(key: "FontFace", section: font.face.owner, raw: font.face.raw, current: font.face.current,
                              variable: font.face.kind == .variable ? font.face.owner : nil)
        popup.identifier = NSUserInterfaceItemIdentifier("font-face:\(font.title)")
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.onAction { [weak self] c in
            guard let value = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            self?.writeFont(font, place: font.face, value: value, what: "Font")
        }
        var controls: [NSView] = [popup]
        if let size = font.size {
            let field = NumberControl(value: GeometryEdit.format(OptionValue.number(size.current) ?? 0), placeholder: "",
                                      min: 1, max: 400, step: 1, unit: "pt", fallback: 10, fieldWidth: 40)
            field.identifier = NSUserInterfaceItemIdentifier("font-size:\(font.title)")
            field.onCommit = { [weak self] v in
                guard let self, !self.inspectorState.isRebuilding, !v.isEmpty else { return }
                self.writeFont(font, place: size, value: v, what: "Font Size")
            }
            field.onStep = { [weak self] v, finished in
                guard let self, finished, !self.inspectorState.isRebuilding else { return }
                self.writeFont(font, place: size, value: v, what: "Font Size")
            }
            field.setContentHuggingPriority(.required, for: .horizontal)
            controls.append(field)
        } else {
            let vary = EditorStyle.label("sizes vary", size: 11, color: .tertiaryLabelColor)
            vary.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            controls.append(vary)
        }
        let bottom = EditorStyle.hstack(controls, spacing: 6)
        var lines: [NSView] = [top]
        if moved { lines.append(EditorStyle.hstack([count, EditorStyle.spacer()], spacing: 0)) }
        if let reach = reachNote(definedIn: fontFile(font.face)) {
            lines.append(caption(reach, color: .tertiaryLabelColor, identifier: "font-reach:\(font.title)"))
        }
        lines.append(bottom)
        let content = EditorStyle.vstack(lines, spacing: 4)
        row.install(content)
        for l in lines { l.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        row.onHover = { [weak self] inside in self?.canvas.relatedNames = inside ? meters : [] }
        return row
    }

    /// The file a font's face is written in (nil: a layer's own options, this widget's).
    func fontFile(_ place: FontSource.Place) -> URL? {
        guard let skin else { return nil }
        switch place.kind {
        case .variable: return skin.sources.location(section: "Variables", key: place.owner)?.file
        case .look: return skin.sources.location(section: place.owner, key: place.key)?.file ?? skin.sources.location(section: place.owner)?.file
        case .layer: return nil
        }
    }

    /// "Changes all 6 Deskset widgets": a value written in a file other widgets share, while "Apply to" says every widget
    /// (nil otherwise: this widget alone changes).
    func reachNote(definedIn file: URL?) -> String? {
        guard appliesToAllWidgets, let file, let reach = sharedReach([file]) else { return nil }
        return "Changes all \(reach.count) \(reach.root) widgets."
    }

    /// Writes a font face or size where it is defined — the shared value (this widget, or every widget), the look, the
    /// layer — as one undo step "Change Font of Title Text".
    func writeFont(_ font: FontSource, place: FontSource.Place, value: String, what: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.writeFont(font, place: place, value: value, what: what) }) { return }
        guard let skin else { return }
        let name = "Change \(what) of \(Self.titleCase(font.title))"
        let toast = "\(what) changed on \(usersPhrase(font.users))"
        switch place.kind {
        case .variable:
            writeSharedValues([(place.owner, value)], undoName: name, toast: toast)
        case .look:
            let defined = skin.sources.location(section: place.owner, key: place.key)?.file
                ?? skin.sources.location(section: place.owner)?.file ?? skin.fileURL
            // A look in a file other widgets share: this widget gets its own [Look] after the includes (later wins).
            let file = skin.isOwnFile(defined) || appliesToAllWidgets ? defined : skin.fileURL
            let reach = sharedReach([file])
            guard perform(reach.map { "\(name) in All \($0.count) Widgets" } ?? name, files: [file], message: nil, {
                try IniWriter.writeValue(value, key: place.key, section: place.owner, fileURL: file)
            }) else { return }
            showToast(reach.map { Self.widened(toast, count: $0.count, root: $0.root) } ?? toast)
        case .layer:
            let target = skin.ownTarget(section: place.owner, key: place.key)
            guard perform(name, files: [target.file], message: nil, {
                try IniWriter.writeValue(value, key: place.key, section: target.section, fileURL: target.file)
            }) else { return }
            showToast(toast)
        }
    }

    // MARK: Update speed (§8.1.2)

    func updateSpeedCard(_ skin: Skin) -> NSView {
        let rainmeter = rows(of: "Rainmeter", kind: .rainmeter)
        let written = rainmeter.first { $0.key.caseInsensitiveCompare("Update") == .orderedSame }
        let ms = Int(written.flatMap { OptionValue.number($0.resolved) } ?? 1000)
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("update-speed")
        popup.setAccessibilityLabel("How often")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let preset = WidgetPresets.updatePreset(for: ms)
        if preset == nil {
            let item = NSMenuItem(title: WidgetPresets.updateTitle(for: ms), action: nil, keyEquivalent: "")
            item.representedObject = ms
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for p in WidgetPresets.updateSpeeds {
            let item = NSMenuItem(title: p.title, action: nil, keyEquivalent: "")
            item.representedObject = p.value
            item.toolTip = p.caption
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: nil, keyEquivalent: "")
        custom.representedObject = "custom"
        menu.addItem(custom)
        popup.menu = menu
        popup.select(menu.items.first { ($0.representedObject as? Int) == (preset?.value ?? ms) })
        popup.onAction { [weak self] c in
            guard let self, let item = (c as? NSPopUpButton)?.selectedItem else { return }
            if item.representedObject as? String == "custom" {
                self.inspectorState.disclosures.insert("widget/update-custom")
                self.rebuildKeepingScroll()
                return
            }
            guard let value = item.representedObject as? Int else { return }
            self.writeUpdateSpeed(value)
        }
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [popup]
        if preset == nil || inspectorState.disclosures.contains("widget/update-custom") {
            let seconds = NumberField(WidgetPresets.number(Double(WidgetPresets.effectiveUpdate(ms)) / 1000, decimals: 3),
                                      placeholder: "1", min: 0.016, max: 86_400)
            seconds.identifier = NSUserInterfaceItemIdentifier("update-seconds")
            seconds.widthAnchor.constraint(equalToConstant: 56).isActive = true
            seconds.onCommit = { [weak self] v in
                guard let self, let s = Double(v) else { return }
                self.writeUpdateSpeed(WidgetPresets.milliseconds(fromSeconds: s))
            }
            views.append(EditorStyle.hstack([EditorStyle.label("every", size: 12, color: .secondaryLabelColor), seconds,
                                             EditorStyle.label("seconds", size: 12, color: .secondaryLabelColor),
                                             EditorStyle.spacer()], spacing: 6))
        }
        var text = WidgetPresets.updateCaption(for: ms)
        if app.state.editor.showIniNames { text += "  Update=\(written?.raw ?? "1000")" }
        views.append(caption(text, identifier: "update-caption"))
        let showsSound = skin.measures.contains { $0.type == "audiolevel" }
        let showsSeconds = skin.measures.contains { m in
            m.type == "time" && WidgetPresets.formatShowsSeconds(m.rawOption("Format") ?? "%H:%M:%S")
        }
        for warning in WidgetPresets.updateWarnings(for: ms, showsSound: showsSound, showsSeconds: showsSeconds) {
            let issue = EditorStyle.issue(warning, width: EditorStyle.minimumControlWidth + EditorStyle.labelColumnWidth)
            issue.identifier = NSUserInterfaceItemIdentifier("update-warning")
            views.append(issue)
        }
        return pageCard("Update Speed", views: views)
    }

    /// Writes `Update=` as one undo step "Change Update Speed".
    func writeUpdateSpeed(_ milliseconds: Int) {
        inspectorState.disclosures.remove("widget/update-custom")
        writeWidgetSetting("Update", value: String(milliseconds), undoName: "Change Update Speed",
                           toast: "Now updates \(WidgetPresets.updateWords(for: milliseconds))")
    }

    /// Writes (or removes, nil) an option of `[Rainmeter]` (or `section`) where it is defined, as one undo step with a
    /// toast.
    @discardableResult
    func writeWidgetSetting(_ key: String, value: String?, undoName: String, toast: String, section: String = "Rainmeter")
        -> Bool {
        writeWidgetSettings([(key, value)], undoName: undoName, toast: toast, section: section)
    }

    @discardableResult
    func writeWidgetSettings(_ values: [(key: String, value: String?)], undoName: String, toast: String,
                             section: String = "Rainmeter") -> Bool {
        if deferUntilCodeIsCommitted({ [weak self] in
            self?.writeWidgetSettings(values, undoName: undoName, toast: toast, section: section)
        }) { return true }
        guard let skin else { return false }
        let name = skin.document.section(named: section)?.name ?? section
        // A setting a file other widgets share makes (a suite's common [Rainmeter]) is never rewritten there: this
        // widget gets its own value after its @Include lines (read later, it wins), and a shared one can't be removed
        // for this widget alone — the toast says so.
        var writes: [KeyWrite] = []
        var kept: [String] = []
        for v in values {
            let file = skin.document.section(named: section) == nil ? skin.fileURL : skin.editTarget(section: section, key: v.key).file
            // A fixed size "set to 0 has no effect" (the manual): this widget's own 0 undoes a shared one.
            let none = ["skinwidth", "skinheight"].contains(v.key.lowercased()) ? "0" : nil
            let shared = skin.sharedDefinition(ofVariable: v.key, section: section) != nil
            if skin.isOwnFile(file) {
                if v.value == nil, shared, let none {
                    writes.append(KeyWrite(file: file, section: name, key: v.key, value: none, afterIncludes: true))
                } else {
                    writes.append(KeyWrite(file: file, section: name, key: v.key, value: v.value))
                    if v.value == nil, shared { kept.append(v.key) }
                }
            } else if let value = v.value ?? none {
                writes.append(KeyWrite(file: skin.fileURL, section: name, key: v.key, value: value, afterIncludes: true))
            } else {
                kept.append(v.key)
            }
        }
        let keptNote = kept.isEmpty ? "" : " Other widgets share this setting, so it still applies here too."
        guard !writes.isEmpty else {
            self.toast.show(keptNote.trimmingCharacters(in: .whitespaces), error: true)
            return false
        }
        let own = writes.filter(\.afterIncludes)
        let verify: ((Skin) -> Bool)? = own.isEmpty ? nil : { reloaded in
            own.allSatisfy { w in reloaded.sources.location(section: w.section, key: w.key).map { reloaded.isOwnFile($0.file) } ?? false }
        }
        guard perform(undoName, files: writes.map(\.file), message: nil, verify: verify, { try Self.apply(writes) }) else {
            return false
        }
        showToast(toast + keptNote)
        return true
    }

    // MARK: On your desktop (§8.1.3)

    /// Whether the edited widget is the one on the desktop now.
    var isWidgetRunning: Bool {
        guard let c = controller, !c.isStopped else { return false }
        return app.controller(for: c.config) === c
    }

    func desktopCard() -> NSView {
        let running = isWidgetRunning
        let state = controller?.state ?? SkinState(file: "")
        let width = EditorStyle.minimumControlWidth + EditorStyle.labelColumnWidth
        inspectorState.desktopShown = state
        // Settings changed elsewhere (the menu bar, the widget's own menu) show here too.
        inspectorState.liveUpdates.append { [weak self] in
            guard let self, let c = self.controller, let shown = self.inspectorState.desktopShown,
                  Self.desktopSettings(c.state) != Self.desktopSettings(shown),
                  RunLoop.current.currentMode != .eventTracking else { return }
            self.rebuildKeepingScroll()
        }
        var views: [NSView] = []
        if !running {
            let show = NSButton(title: "Show on Desktop", target: nil, action: nil)
            show.bezelStyle = .rounded
            show.controlSize = .small
            show.identifier = NSUserInterfaceItemIdentifier("show-on-desktop")
            show.onAction { [weak self] _ in
                guard let self else { return }
                self.app.activate(config: self.config, file: self.controller?.file)
            }
            views.append(caption("This widget isn't on your desktop right now.", identifier: "desktop-not-running"))
            views.append(EditorStyle.hstack([show, EditorStyle.spacer()], spacing: 0))
        }
        // Stacking: three segments, or all five levels for a widget at an in-between level (the value is kept).
        let stacking: NSControl
        if WidgetPresets.stackingControl(for: state.alwaysOnTop) == .segments {
            let seg = NSSegmentedControl(labels: WidgetPresets.stacking.map(\.title), trackingMode: .selectOne, target: nil,
                                         action: nil)
            seg.controlSize = .small
            seg.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            seg.selectedSegment = WidgetPresets.stacking.firstIndex { $0.value == state.alwaysOnTop } ?? -1
            seg.onAction { [weak self] c in
                guard let s = c as? NSSegmentedControl, s.selectedSegment >= 0 else { return }
                self?.setStacking(WidgetPresets.stacking[s.selectedSegment].value)
            }
            stacking = seg
        } else {
            let popup = NSPopUpButton()
            for level in WidgetPresets.stackingAll {
                popup.addItem(withTitle: level.title)
                popup.lastItem?.representedObject = level.value
            }
            popup.selectItem(at: WidgetPresets.stackingAll.firstIndex { $0.value == state.alwaysOnTop } ?? 0)
            popup.onAction { [weak self] c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? Int else { return }
                self?.setStacking(v)
            }
            stacking = popup
        }
        stacking.identifier = NSUserInterfaceItemIdentifier("stacking")
        stacking.setAccessibilityLabel("Stacking")
        stacking.isEnabled = running
        views.append(stackedLabel("Stacking", key: "AlwaysOnTop"))
        views.append(stacking)
        views.append(caption(WidgetPresets.stackingCaption(for: state.alwaysOnTop), identifier: "stacking-caption"))

        let lock = CheckboxRow(title: "Lock position", width: width)
        lock.box.state = state.draggable ? .off : .on
        lock.box.identifier = NSUserInterfaceItemIdentifier("lock-position")
        lock.box.isEnabled = running
        lock.box.onAction { [weak self] b in
            let locked = (b as? NSButton)?.state == .on
            self?.changeDesktop(locked ? "Lock Position" : "Unlock Position", toast: locked ? "Position locked" : "Position unlocked") {
                $0.draggable = !locked
            }
        }
        views.append(lock)
        if !state.draggable {
            views.append(caption("It can't be dragged. Turn this off here or from the widget's right-click menu.",
                                 color: .tertiaryLabelColor))
        }
        let through = CheckboxRow(title: "Let clicks pass through", width: width)
        through.box.state = state.clickThrough ? .on : .off
        through.box.identifier = NSUserInterfaceItemIdentifier("click-through")
        through.box.isEnabled = running
        through.box.onAction { [weak self] b in
            let on = (b as? NSButton)?.state == .on
            self?.changeDesktop(on ? "Let Clicks Pass Through" : "Catch Clicks",
                                toast: on ? "Clicks pass through" : "Clicks reach the widget again") { $0.clickThrough = on }
        }
        views.append(through)
        if state.clickThrough {
            views.append(caption("Clicks reach whatever is behind it, so you can't click or drag it. Turn this off here or "
                                 + "from Deskset's menu bar icon.", color: .tertiaryLabelColor))
        }
        let opacity = PercentControl(value: Double(state.alphaValue))
        opacity.identifier = NSUserInterfaceItemIdentifier("desktop-opacity")
        opacity.slider.isEnabled = running
        opacity.field.isEnabled = running
        var dragStart: SkinState?
        opacity.onChange = { [weak self] raw, finished in
            guard let self, let c = self.controller, self.isWidgetRunning, let v = Int(raw) else { return }
            if dragStart == nil { dragStart = c.state }
            if finished, let start = dragStart {
                dragStart = nil
                self.changeDesktop("Change Opacity", toast: "Opacity \(Int((Double(v) / 255 * 100).rounded()))%", from: start) {
                    $0.alphaValue = v
                }
            } else {
                self.app.changeSettings(of: c) { $0.alphaValue = v }
                self.inspectorState.desktopShown = c.state
            }
        }
        views.append(stackedLabel("Opacity", key: "AlphaValue"))
        views.append(opacity)

        // What differs from the defaults is counted, and opens the options by itself (P4): a widget that hides when
        // pointed at must not hide why.
        let inUse = [!state.snapEdges, !state.keepOnScreen, state.fadeDuration != 250, state.onHover != 0].filter { $0 }.count
        let open = isDisclosureOpen("widget/desktop-more", automatic: inUse > 0)
        views.append(disclosureHeader("More Desktop Options", id: "widget/desktop-more",
                                      summary: "snapping, keep on screen, fade, when pointed at", inUse: inUse, open: open,
                                      automatic: inUse > 0))
        if open {
            let snap = CheckboxRow(title: "Snap to screen edges and other widgets", width: width)
            snap.box.state = state.snapEdges ? .on : .off
            snap.box.identifier = NSUserInterfaceItemIdentifier("snap-edges")
            snap.box.isEnabled = running
            snap.box.onAction { [weak self] b in
                let on = (b as? NSButton)?.state == .on
                self?.changeDesktop(on ? "Snap to Edges" : "Don't Snap to Edges", toast: on ? "Snaps to edges" : "Doesn't snap") {
                    $0.snapEdges = on
                }
            }
            let keep = CheckboxRow(title: "Keep on screen", width: width)
            keep.box.state = state.keepOnScreen ? .on : .off
            keep.box.identifier = NSUserInterfaceItemIdentifier("keep-on-screen")
            keep.box.isEnabled = running
            keep.box.onAction { [weak self] b in
                let on = (b as? NSButton)?.state == .on
                self?.changeDesktop(on ? "Keep on Screen" : "Allow Off Screen", toast: on ? "Kept on screen" : "Can go off screen") {
                    $0.keepOnScreen = on
                }
            }
            let fade = NumberControl(value: WidgetPresets.fadeSeconds(state.fadeDuration), placeholder: "0.25", min: 0, max: 10,
                                     step: nil, unit: "seconds", fallback: 0.25, fieldWidth: 44)
            fade.identifier = NSUserInterfaceItemIdentifier("fade-time")
            fade.field.isEnabled = running
            fade.onCommit = { [weak self] v in
                guard let s = Double(v) else { return }
                let ms = Int((s * 1000).rounded())
                self?.changeDesktop("Change Fade Time", toast: "Fades in \(WidgetPresets.fadeSeconds(ms)) seconds") {
                    $0.fadeDuration = ms
                }
            }
            let hover = NSPopUpButton()
            for p in WidgetPresets.onHover {
                hover.addItem(withTitle: p.title)
                hover.lastItem?.representedObject = p.value
            }
            hover.selectItem(at: WidgetPresets.onHover.firstIndex { $0.value == state.onHover } ?? 0)
            hover.identifier = NSUserInterfaceItemIdentifier("on-hover")
            hover.isEnabled = running
            hover.onAction { [weak self] c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? Int else { return }
                let title = WidgetPresets.onHover.first { $0.value == v }?.title ?? ""
                self?.changeDesktop("Change Pointer Behavior", toast: "When pointed at: \(title.lowercased())") { $0.onHover = v }
            }
            views.append(snap)
            views.append(keep)
            views.append(stackedLabel("Fade time", key: "FadeDuration"))
            views.append(fade)
            views.append(stackedLabel("When the pointer is over it", key: "OnHover"))
            views.append(EditorStyle.hstack([hover, EditorStyle.spacer()], spacing: 0))
        }
        return pageCard("On Your Desktop", note: "Applies right away on this Mac.", views: views)
    }

    /// The settings the ON YOUR DESKTOP card shows (not the position, which moves with every drag on the desktop).
    static func desktopSettings(_ s: SkinState) -> [Int] {
        [s.alwaysOnTop, s.draggable ? 1 : 0, s.clickThrough ? 1 : 0, s.alphaValue, s.snapEdges ? 1 : 0,
         s.keepOnScreen ? 1 : 0, s.fadeDuration, s.onHover]
    }

    func setStacking(_ value: Int) {
        let name = WidgetPresets.stackingName(for: value)
        changeDesktop(name, toast: name.prefix(1) + name.dropFirst().lowercased()) { $0.alwaysOnTop = value }
    }

    /// Changes the running widget's desktop settings (never its file) as one named undo step with a toast.
    func changeDesktop(_ name: String, toast: String, from start: SkinState? = nil, _ change: (inout SkinState) -> Void) {
        guard let c = controller, isWidgetRunning else { return }
        let before = start ?? c.state
        app.changeSettings(of: c, change)
        inspectorState.desktopShown = c.state
        registerDesktopUndo(before, name: name)
        showToast(toast)
        rebuildKeepingScroll()
    }

    /// One undo step that puts the desktop settings back (and a redo that sets them again).
    func registerDesktopUndo(_ state: SkinState, name: String) {
        guard let manager = window?.undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            guard let c = target.controller, target.isWidgetRunning else { return }
            let current = c.state
            let undoing = manager.isUndoing
            target.app.changeSettings(of: c) { s in
                s.alwaysOnTop = state.alwaysOnTop
                s.draggable = state.draggable
                s.clickThrough = state.clickThrough
                s.alphaValue = state.alphaValue
                s.snapEdges = state.snapEdges
                s.keepOnScreen = state.keepOnScreen
                s.fadeDuration = state.fadeDuration
                s.onHover = state.onHover
            }
            target.registerDesktopUndo(current, name: name)
            // "Undid Always on Top · [Redo]" (§10).
            let again = undoing ? ToastAction("Redo") { [weak manager] in manager?.redo() }
                : ToastAction("Undo") { [weak manager] in manager?.undo() }
            target.toast.show(undoing ? "Undid \(name)" : "Redid \(name)", actions: [again])
            target.rebuildKeepingScroll()
        }
        manager.setActionName(name)
    }

    // MARK: Size and spacing (§8.1.4)

    /// The card, and the makers of its shared sizes' rows (added one by one: `addCard`).
    func sizeAndSpacingCard(_ skin: Skin, index: ValueUsageIndex) -> (card: EditorCard, rows: [() -> NSView]) {
        let rainmeter = rows(of: "Rainmeter", kind: .rainmeter)
        func row(_ key: String) -> Row? { rainmeter.first { $0.key.caseInsensitiveCompare(key) == .orderedSame } }
        let n = EditorStyle.number
        var views: [NSView] = []
        // Size: fits its content, or fixed.
        let fixed = row("SkinWidth") != nil || row("SkinHeight") != nil
        let size = NSSegmentedControl(labels: ["Fits Its Content", "Fixed Size"], trackingMode: .selectOne, target: nil, action: nil)
        size.controlSize = .small
        size.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        size.selectedSegment = fixed ? 1 : 0
        size.identifier = NSUserInterfaceItemIdentifier("widget-size-mode")
        size.setAccessibilityLabel("Size")
        size.onAction { [weak self] c in
            guard let self, let s = c as? NSSegmentedControl, let skin = self.skin else { return }
            if s.selectedSegment == 1 {
                self.writeWidgetSettings([("SkinWidth", n(skin.width)), ("SkinHeight", n(skin.height))], undoName: "Fix Widget Size",
                                         toast: "The widget stays \(n(skin.width)) × \(n(skin.height))")
            } else {
                self.writeWidgetSettings([("SkinWidth", nil), ("SkinHeight", nil)], undoName: "Fit Widget to Its Content",
                                         toast: "The widget fits its content")
            }
        }
        let now = EditorStyle.label("\(n(skin.width)) × \(n(skin.height)) px now", size: 11, color: .tertiaryLabelColor)
        now.identifier = NSUserInterfaceItemIdentifier("widget-size-now")
        views.append(stackedLabel("Size", key: "SkinWidth"))
        views.append(size)
        views.append(now)
        if fixed {
            func field(_ key: String, _ value: Double) -> NumberField {
                let f = NumberField(row(key).map { $0.raw } ?? n(value), placeholder: n(value), min: 1, max: Skin.maxSide)
                f.identifier = NSUserInterfaceItemIdentifier("widget-\(key)")
                f.widthAnchor.constraint(equalToConstant: 52).isActive = true
                f.onCommit = { [weak self] v in
                    guard let self, !v.isEmpty else { return }
                    self.writeWidgetSetting(key, value: v, undoName: "Change Widget Size", toast: "Widget size changed")
                }
                return f
            }
            views.append(EditorStyle.hstack([EditorStyle.caption("W"), field("SkinWidth", skin.width), EditorStyle.caption("×  H"),
                                             field("SkinHeight", skin.height), EditorStyle.label("px", size: 11, color: .secondaryLabelColor),
                                             EditorStyle.spacer()], spacing: 5))
        }
        views.append(behindEverything(skin, rows: rainmeter))
        // Shared sizes: one row each, its name and who uses it over its value.
        let sizes = index.sharedSizes().filter { $0.variableName != nil }
        var note = "A shared size changes every layer that uses it."
        if sizes.contains(where: { if case .shared = $0.origin { return true } else { return false } }) {
            let name = ManageModel.metadataValue(skin.metadata, "Name") ?? String(skin.config.split(separator: "\\").last ?? "")
            note += appliesToAllWidgets
                ? " Sizes shared with other widgets change them all — see Apply to, under Colors and Fonts."
                : " Only \(name) changes — see Apply to, under Colors and Fonts."
        }
        let card = pageCard("Size and Spacing", note: sizes.isEmpty ? nil : note, views: views)
        return (card, sizes.map { value in { self.sizeRow(value, skin: skin) } })
    }

    /// One shared size (§8.1.4): `Bar width   16 bars` over `[9] px` — a calculated one shows its value with Edit
    /// Calculation…. Pointing at it outlines who uses it (P7); the count selects them.
    func sizeRow(_ value: ValueUsageIndex.Value, skin: Skin) -> ValueRowView {
        let name = value.variableName ?? ""
        let expert = app.state.editor.showIniNames
        let n = EditorStyle.number
        let words = ValueUsageIndex.humanizedVariable(name)
        let row = ValueRowView()
        row.identifier = NSUserInterfaceItemIdentifier("size-row:\(name)")
        let title = EditorStyle.label(words, size: 12.5)
        title.identifier = NSUserInterfaceItemIdentifier("size-name:\(name)")
        title.toolTip = expert ? "\(name) = \(value.raw)" : words
        let meters = layersReached(value.sections)
        let users = usersPhrase(value.sections, atLeast: value.isAtLeast)
        let count = countLink(users, layers: meters, identifier: "size-count:\(name)")
        let (line, moved) = nameLine(lead: nil, name: title, trailing: [], count: count)
        var lines: [NSView] = [line]
        if moved { lines.append(EditorStyle.hstack([count, EditorStyle.spacer()], spacing: 0)) }
        if expert { lines.append(EditorStyle.mono(name, size: 10)) }
        let write: (String) -> Void = { [weak self] v in
            guard let self, !self.inspectorState.isRebuilding, !v.isEmpty else { return }
            self.writeSharedValues([(name, v)], undoName: "Change \(Self.titleCase(words))", toast: "\(words) changed on \(users)")
        }
        if value.isCalculated {
            let current = OptionValue.number(value.current).map { n($0) } ?? value.current
            let shown = EditorStyle.label("\(current) px · calculated", size: 12, color: .secondaryLabelColor)
            shown.identifier = NSUserInterfaceItemIdentifier("size-value:\(name)")
            let id = "widget/calculation/\(name)"
            let open = inspectorState.openCalculations.contains(id)
            let edit = pageLink(open ? "Hide Calculation" : "Edit Calculation…")
            edit.identifier = NSUserInterfaceItemIdentifier("edit-calculation:\(name)")
            edit.onAction { [weak self] _ in
                guard let self else { return }
                if open { self.inspectorState.openCalculations.remove(id) } else { self.inspectorState.openCalculations.insert(id) }
                self.rebuildKeepingScroll()
            }
            lines.append(EditorStyle.hstack([shown, EditorStyle.spacer(), edit], spacing: 6))
            if open {
                let formula = ValueField(value.raw, placeholder: "Calculation", monospaced: true)
                formula.identifier = NSUserInterfaceItemIdentifier("calculation:\(name)")
                formula.onCommit = write
                lines.append(formula)
                lines.append(caption("Math on other values. Numbers and names of shared sizes work here.", color: .tertiaryLabelColor))
            }
        } else {
            let field = NumberControl(value: value.current, placeholder: "", min: nil, max: nil, step: 1, unit: "px",
                                      fallback: OptionValue.number(value.current) ?? 0, fieldWidth: 44)
            field.identifier = NSUserInterfaceItemIdentifier("size:\(name)")
            field.onCommit = write
            field.onStep = { v, finished in if finished { write(v) } }
            lines.append(field)
        }
        if let reach = reachNote(definedIn: value.file) {
            lines.append(caption(reach, color: .tertiaryLabelColor, identifier: "size-reach:\(name)"))
        }
        let content = EditorStyle.vstack(lines, spacing: 4)
        row.install(content)
        for l in lines { l.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        row.onHover = { [weak self] inside in self?.canvas.relatedNames = inside ? meters : [] }
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(words), used by \(users)")
        return row
    }

    /// "Behind everything": the layer called Background, or what the widget draws itself (nothing, a color, a
    /// picture).
    func behindEverything(_ skin: Skin, rows rainmeter: [Row]) -> NSView {
        let drawsItself = skin.settings.backgroundMode != 1 || skin.settings.backgroundImage != nil
        if let name = skin.detectedBackgroundLayer(), !drawsItself {
            var tone = ""
            if let panel = widgetPanelColor() {
                let l = (0.2126 * panel.r + 0.7152 * panel.g + 0.0722 * panel.b) / 255
                tone = l < 0.35 ? "dark " : l > 0.7 ? "light " : ""
            }
            let shown = displayName(ofSection: name)
            let quoted = shown.hasPrefix("“") ? shown : "“\(shown)”"
            let sentence = caption("Nothing — the \(tone)panel is the layer \(quoted).", identifier: "behind-everything")
            let select = pageLink("Select It")
            select.identifier = NSUserInterfaceItemIdentifier("select-background")
            select.onAction { [weak self] _ in self?.select(section: name) }
            let label = stackedLabel("Behind everything", key: "BackgroundMode")
            let stack = EditorStyle.vstack([label, sentence, EditorStyle.hstack([select, EditorStyle.spacer()], spacing: 0)], spacing: 3)
            sentence.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            return stack
        }
        // Nothing · A Color · A Picture, and the rows each one needs — each label above its control, as in the rest of
        // the card.
        let groups = EditorSchema.skinGroups
        let lookup = valueLookup(rainmeter)
        var views: [NSView] = []
        for p in EditorSchema.visibleGroups(groups, values: lookup).flatMap(\.properties)
            where ["BackgroundMode", "SolidColor", "SolidColor2", "GradientAngle", "Background", "BackgroundMargins"].contains(p.key) {
            let item = propertyRow(p, section: "Rainmeter", row: row(for: p, in: rainmeter), groups: groups)
            views.append(stackedLabel(p.label, key: p.key))
            views.append(item.control)
        }
        let stack = EditorStyle.vstack(views, spacing: 4)
        for v in views { v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        return stack
    }

    // MARK: Disclosures (§8.1.5)

    /// "Something's Missing (N)": files and looks the widget's own files name that aren't there — a broken install,
    /// not a Mac difference — in plain words; open by itself, as it explains layers that draw nothing.
    func missingDisclosure(_ skin: Skin) -> NSView {
        let id = "widget/missing"
        var lines: [String] = []
        for file in skin.missingIncludeFiles {
            lines.append("A file this widget needs is missing: \(file). What it holds (colors, sizes, looks) is left out.")
        }
        for (look, layers) in skin.missingLooks {
            let who = layers.count == 1 ? displayName(ofSection: layers[0]) : "\(layers.count) layers"
            lines.append("The look “\(ValueUsageIndex.humanizedLook(look))” that \(who) \(layers.count == 1 ? "uses" : "use") "
                + "is missing, so \(layers.count == 1 ? "it draws" : "they draw") without it.")
        }
        let open = isDisclosureOpen(id, automatic: true)
        let header = disclosureHeader("Something's Missing (\(lines.count))", id: id, summary: "", open: open, automatic: true)
        var views: [NSView] = [header]
        if open {
            for (i, line) in lines.prefix(12).enumerated() { views.append(caption(line, identifier: "missing:\(i)")) }
            if app.state.editor.showIniNames {
                for w in skin.loadWarnings { views.append(caption(w, color: .tertiaryLabelColor)) }
            }
        }
        return disclosureCard(id, views: views)
    }

    func issuesDisclosure(_ skin: Skin) -> NSView {
        let id = "widget/issues"
        let open = isDisclosureOpen(id)
        // In plain words (§8.1.5): who it is about and what that means; the note as written with Rainmeter Details.
        var lines: [(plain: String, raw: [String])] = []
        for issue in skin.issues {
            let plain = WidgetPresets.plainIssue(issue, in: skin, name: { [weak self] in self?.displayName(ofSection: $0) ?? $0 })
            if let i = lines.firstIndex(where: { $0.plain == plain }) { lines[i].raw.append(issue) } else { lines.append((plain, [issue])) }
        }
        var views: [NSView] = [disclosureHeader("Doesn't Work on a Mac (\(lines.count))", id: id, summary: "", open: open)]
        if open {
            for (i, line) in lines.prefix(12).enumerated() {
                views.append(caption(line.plain, identifier: "issue:\(i)"))
                if app.state.editor.showIniNames {
                    for raw in line.raw {
                        let written = caption(raw, color: .tertiaryLabelColor)
                        written.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                        views.append(written)
                    }
                }
            }
            if lines.count > 12 { views.append(caption("and \(lines.count - 12) more", color: .tertiaryLabelColor)) }
        }
        return disclosureCard(id, views: views)
    }

    func aboutDisclosure(_ skin: Skin) -> NSView {
        let id = "widget/about"
        let open = isDisclosureOpen(id)
        var views: [NSView] = [disclosureHeader("About This Widget", id: id, summary: "name, author, version, description",
                                                open: open)]
        if open {
            let metadata = rows(of: "Metadata", kind: .metadata)
            var items: [InspectorRow] = []
            for p in EditorSchema.aboutGroup.properties {
                let value = metadata.first { $0.key.caseInsensitiveCompare(p.key) == .orderedSame }?.raw ?? ""
                let field = ValueField(value, placeholder: "", monospaced: false)
                field.identifier = NSUserInterfaceItemIdentifier("about:\(p.key)")
                field.onCommit = { [weak self] v in
                    guard let self, !self.inspectorState.isRebuilding else { return }
                    self.writeWidgetSetting(p.key, value: v.isEmpty ? nil : v, undoName: "Change \(p.label)",
                                            toast: "\(p.label) changed", section: "Metadata")
                }
                items.append(InspectorRow(label: pageLabel(p.label, key: p.key), control: field))
            }
            views.append(cardNote(EditorSchema.aboutGroup.summary))
            views.append(EditorStyle.grid(items))
        }
        return disclosureCard(id, views: views)
    }

    /// How many of More Widget Options' values are not their default (quiet ones aside), for "· N in use".
    func widgetOptionsInUse(_ rows: [Row]) -> Int {
        let titles = ["Timing", "Size", "Dragging", "Right-click menu", "When the widget…", "When someone else installs it",
                      "Group names"]
        var count = 0
        // A menu item counts once (its title), not again for its action.
        for p in EditorSchema.skinGroups.filter({ titles.contains($0.title) }).flatMap(\.properties)
            where p.level != .quiet && p.key != "ContextAction" {
            guard let r = row(for: p, in: rows), !r.raw.isEmpty else { continue }
            if p.defaultValue.isEmpty || r.resolved.trimmingCharacters(in: .whitespaces) != p.defaultValue { count += 1 }
        }
        // Further menu items (ContextTitle2…).
        count += rows.filter { r in
            let k = r.key.lowercased()
            return k.hasPrefix("contexttitle") && k != "contexttitle" && !r.raw.isEmpty
        }.count
        return count
    }

    func moreWidgetOptions(_ skin: Skin, index: ValueUsageIndex) -> NSView {
        let id = "widget/more"
        let rainmeter = rows(of: "Rainmeter", kind: .rainmeter)
        let inUse = widgetOptionsInUse(rainmeter)
        let open = isDisclosureOpen(id, automatic: inUse > 0)
        var views: [NSView] = [disclosureHeader("More Widget Options", id: id, summary: "timing, right-click menu, actions, looks",
                                                inUse: inUse, open: open, automatic: inUse > 0)]
        guard open else { return disclosureCard(id, views: views) }
        func value(_ key: String) -> Row? { rainmeter.first { $0.key.caseInsensitiveCompare(key) == .orderedSame } }
        func heading(_ text: String) -> NSTextField {
            let l = EditorStyle.label(text, size: 11.5, weight: .semibold, color: .secondaryLabelColor)
            l.identifier = NSUserInterfaceItemIdentifier("more-heading:\(text)")
            return l
        }
        func codeLink(_ location: IniSourceLocation?) -> NSView {
            let edit = pageLink("Edit in Code ›")
            edit.onAction { [weak self] _ in self?.showInCode(location) }
            return EditorStyle.hstack([edit, EditorStyle.spacer()], spacing: 0)
        }
        func choices(_ presets: [WidgetPresets.Preset], current: Int, title: (Int) -> String, identifier: String,
                     custom: (() -> Void)? = nil, write: @escaping (Int) -> Void) -> NSPopUpButton {
            let popup = NSPopUpButton()
            var list = presets
            if !list.contains(where: { $0.value == current }) { list.insert(.init(title(current), current), at: 0) }
            for p in list {
                popup.addItem(withTitle: p.title)
                popup.lastItem?.representedObject = p.value
            }
            if custom != nil {
                popup.menu?.addItem(.separator())
                popup.addItem(withTitle: "Custom…")
                popup.lastItem?.representedObject = "custom"
            }
            popup.selectItem(at: list.firstIndex { $0.value == current } ?? 0)
            popup.identifier = NSUserInterfaceItemIdentifier(identifier)
            popup.onAction { c in
                let chosen = (c as? NSPopUpButton)?.selectedItem?.representedObject
                if chosen as? String == "custom" { custom?(); return }
                guard let v = chosen as? Int else { return }
                write(v)
            }
            return popup
        }
        let width = EditorStyle.minimumControlWidth + EditorStyle.labelColumnWidth

        // Timing.
        views.append(heading("Timing"))
        let divider = Int(value("DefaultUpdateDivider").flatMap { OptionValue.number($0.resolved) } ?? 1)
        let writeRedraw: (Int) -> Void = { [weak self] v in
            self?.inspectorState.disclosures.remove("widget/redraw-custom")
            self?.writeWidgetSetting("DefaultUpdateDivider", value: v == 1 ? nil : String(v), undoName: "Change Redraw Timing",
                                     toast: "Layers redraw \(WidgetPresets.redrawTitle(for: v).lowercased())")
        }
        let redraw = choices(WidgetPresets.redrawEvery, current: divider, title: WidgetPresets.redrawTitle,
                             identifier: "redraw-layers", custom: { [weak self] in
                                 self?.inspectorState.disclosures.insert("widget/redraw-custom")
                                 self?.rebuildKeepingScroll()
                             }, write: writeRedraw)
        let ms = Int(value("TransitionUpdate").flatMap { OptionValue.number($0.resolved) } ?? 100)
        let transition = choices(WidgetPresets.transitionSpeeds, current: ms, title: WidgetPresets.transitionTitle,
                                 identifier: "transition-speed") { [weak self] v in
            self?.writeWidgetSetting("TransitionUpdate", value: v == 100 ? nil : String(v), undoName: "Change Transition Speed",
                                     toast: "Transitions at \(WidgetPresets.transitionTitle(for: v))")
        }
        var timing = [InspectorRow(label: pageLabel("Redraw layers", key: "DefaultUpdateDivider"), control: redraw)]
        // Custom…: "every [3] updates".
        if inspectorState.disclosures.contains("widget/redraw-custom") || !WidgetPresets.redrawEvery.contains(where: { $0.value == divider }) {
            let every = NumberField(String(max(divider, 1)), placeholder: "1", min: 1, max: 10_000)
            every.identifier = NSUserInterfaceItemIdentifier("redraw-every")
            every.widthAnchor.constraint(equalToConstant: 44).isActive = true
            every.onCommit = { v in if let n = Int(v), n >= 1 { writeRedraw(n) } }
            timing.append(InspectorRow(label: nil, control: EditorStyle.hstack([
                EditorStyle.label("every", size: 12, color: .secondaryLabelColor), every,
                EditorStyle.label("updates", size: 12, color: .secondaryLabelColor), EditorStyle.spacer()], spacing: 6)))
        }
        timing.append(InspectorRow(label: pageLabel("Transition speed", key: "TransitionUpdate"), control: transition))
        views.append(EditorStyle.grid(timing))

        // Size.
        views.append(heading("Size"))
        func flag(_ key: String, _ title: String, _ note: String, default on: Bool) -> [NSView] {
            let box = CheckboxRow(title: title, width: width)
            let current = value(key).flatMap { OptionValue.bool($0.resolved) } ?? on
            box.box.state = current ? .on : .off
            box.box.identifier = NSUserInterfaceItemIdentifier("widget-\(key)")
            box.box.onAction { [weak self] b in
                let checked = (b as? NSButton)?.state == .on
                self?.writeWidgetSetting(key, value: checked ? "1" : "0",
                                         undoName: "\(checked ? "Turn On" : "Turn Off") \(Self.titleCase(title))",
                                         toast: "\(title): \(checked ? "on" : "off")")
            }
            return [box, caption(note, color: .tertiaryLabelColor)]
        }
        views += flag("DynamicWindowSize", "Resize whenever content changes", "Only needed when layers change size while running.",
                      default: false)
        views += flag("AccurateText", "Tight text boxes", "Text boxes hug the letters. Recommended.", default: false)

        // Dragging.
        views.append(heading("Dragging"))
        let margins = InsetsControl.values(of: value("DragMargins")?.resolved ?? "0,0,0,0") ?? ["0", "0", "0", "0"]
        let insets = InsetsControl(values: margins, linked: value("DragMargins") != nil && Set(margins).count <= 1, spelledOut: true)
        insets.identifier = NSUserInterfaceItemIdentifier("drag-margins")
        insets.onFieldChange = { [weak self] i, v, linked in
            let combined = InsetsControl.combined(margins, index: i, value: v, linked: linked)
            self?.writeWidgetSetting("DragMargins", value: combined == "0,0,0,0" ? nil : combined, undoName: "Change Drag Edges",
                                     toast: "Edges that don't drag the widget changed")
        }
        views.append(caption("Edges that don't drag the widget, in px", color: .secondaryLabelColor))
        views.append(insets)

        // Right-click menu.
        views.append(heading("Right-click menu"))
        views.append(caption("Extra items in the widget's right-click menu.", color: .tertiaryLabelColor))
        var n = 1
        var items: [(title: Row, action: Row?)] = []
        while let title = value(n == 1 ? "ContextTitle" : "ContextTitle\(n)") {
            items.append((title, value(n == 1 ? "ContextAction" : "ContextAction\(n)")))
            n += 1
        }
        for (i, item) in items.enumerated() { views += menuItemViews(i + 1, item: item, all: items) }
        let add = pageLink("Add Menu Item")
        add.image = EditorStyle.image("plus", size: 10, weight: .semibold)
        add.imagePosition = .imageLeading
        add.identifier = NSUserInterfaceItemIdentifier("add-menu-item")
        let next = n
        add.onAction { [weak self] _ in
            guard let self else { return }
            let suffix = next == 1 ? "" : String(next)
            // It opens for editing at once: its name is typed here, not in the code.
            self.inspectorState.disclosures.insert("widget/menu-item/\(next)")
            self.writeWidgetSettings([("ContextTitle\(suffix)", "New item"), ("ContextAction\(suffix)", "[!Refresh]")],
                                     undoName: "Add Menu Item", toast: "Added “New item” to the right-click menu")
            onNextTurn { [weak self] in
                guard let self, let field = self.inspectorStack.findSubview(where: {
                    $0.identifier?.rawValue == "menu-item-name:\(next)"
                }) as? NSTextField else { return }
                self.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
        views.append(EditorStyle.hstack([add, EditorStyle.spacer()], spacing: 0))

        // When the widget… (P5, P11: a choice only where it can't harm — a reload when the widget opens or updates
        // would reload it again and again — anything else is written in the code).
        views.append(heading("When the widget…"))
        var actions: [InspectorRow] = []
        let rainmeterLocation = skin.sources.location(section: "Rainmeter")
        for (key, label) in [("OnRefreshAction", "Opens"), ("OnUpdateAction", "Updates"), ("OnCloseAction", "Closes"),
                             ("OnFocusAction", "Gets focus"), ("OnUnfocusAction", "Loses focus"), ("OnWakeAction", "Wakes from sleep")] {
            let raw = value(key)?.resolved ?? ""
            let control: NSView
            if raw.isEmpty {
                let popup = NSPopUpButton()
                popup.addItem(withTitle: "No action")
                for preset in WidgetPresets.whenTheWidgetChoices(key) {
                    popup.addItem(withTitle: preset.title)
                    popup.lastItem?.representedObject = preset.action
                }
                popup.menu?.addItem(.separator())
                popup.addItem(withTitle: "Edit in Code…")
                popup.lastItem?.representedObject = "code"
                popup.identifier = NSUserInterfaceItemIdentifier("when-\(key)")
                popup.onAction { [weak self] c in
                    guard let popup = c as? NSPopUpButton, let v = popup.selectedItem?.representedObject as? String else { return }
                    if v == "code" {
                        popup.selectItem(at: 0)
                        self?.showInCode(rainmeterLocation)
                        return
                    }
                    let title = popup.selectedItem?.title.lowercased() ?? ""
                    self?.writeWidgetSetting(key, value: v, undoName: "Change What Happens When It \(Self.titleCase(label))",
                                             toast: "When it \(label.lowercased()): \(title)")
                }
                control = popup
            } else {
                control = EditorStyle.vstack([caption(Self.actionSentence(raw), identifier: "when-\(key)"),
                                              codeLink(value(key)?.location)], spacing: 1)
            }
            actions.append(InspectorRow(label: pageLabel(label, key: key), control: control))
        }
        views.append(EditorStyle.grid(actions))

        // Looks.
        let looks = allItems.filter { $0.kind == .other }
        if !looks.isEmpty {
            views.append(heading("Looks"))
            for look in looks {
                let users = Self.styleUsers(look.title, in: skin)
                let link = NSButton(title: "\(ValueUsageIndex.humanizedLook(look.title)) look · \(users.isEmpty ? "not used" : usersPhrase(users)) ›",
                                    target: nil, action: nil)
                link.isBordered = false
                link.font = .systemFont(ofSize: 11.5)
                link.contentTintColor = .controlAccentColor
                link.lineBreakMode = .byTruncatingTail
                link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                link.identifier = NSUserInterfaceItemIdentifier("look:\(look.title)")
                link.toolTip = app.state.editor.showIniNames ? look.title : "Select the layers using it"
                link.onAction { [weak self] _ in
                    if users.isEmpty { self?.select(section: look.title) } else { self?.selectLayers(users) }
                }
                views.append(EditorStyle.hstack([link, EditorStyle.spacer()], spacing: 0))
            }
        }

        // When someone else installs it.
        views.append(heading("When someone else installs it"))
        views.append(caption("Used the first time someone installs this widget. To change it on this Mac, use On Your Desktop.",
                             color: .tertiaryLabelColor))
        var defaults: [InspectorRow] = []
        let defaultStacking = Int(value("DefaultAlwaysOnTop").flatMap { OptionValue.number($0.resolved) } ?? -2)
        let stacking = choices(WidgetPresets.stackingAll.map { WidgetPresets.Preset($0.title, $0.value) }, current: defaultStacking,
                               title: WidgetPresets.stackingName, identifier: "default-stacking") { [weak self] v in
            self?.writeWidgetSetting("DefaultAlwaysOnTop", value: String(v), undoName: "Change Stacking for New Installs",
                                     toast: "New installs start \(WidgetPresets.stackingAll.first { $0.value == v }?.title.lowercased() ?? "")")
        }
        defaults.append(InspectorRow(label: pageLabel("Stacking", key: "DefaultAlwaysOnTop"), control: stacking))
        func defaultFlag(_ key: String, _ title: String, inverted: Bool, default on: Bool) -> InspectorRow {
            let box = CheckboxRow(title: title, width: EditorStyle.minimumControlWidth)
            let current = value(key).flatMap { OptionValue.bool($0.resolved) } ?? on
            box.box.state = (inverted ? !current : current) ? .on : .off
            box.box.identifier = NSUserInterfaceItemIdentifier("widget-\(key)")
            box.box.onAction { [weak self] b in
                let checked = (b as? NSButton)?.state == .on
                let stored = inverted ? !checked : checked
                self?.writeWidgetSetting(key, value: stored ? "1" : "0", undoName: "Change \(Self.titleCase(title)) for New Installs",
                                         toast: "New installs: \(title.lowercased()) \(checked ? "on" : "off")")
            }
            return InspectorRow(label: nil, control: box)
        }
        defaults.append(defaultFlag("DefaultDraggable", "Lock position", inverted: true, default: true))
        defaults.append(defaultFlag("DefaultClickThrough", "Let clicks pass through", inverted: false, default: false))
        let alpha = PercentControl(value: value("DefaultAlphaValue").flatMap { OptionValue.number($0.resolved) } ?? 255)
        alpha.identifier = NSUserInterfaceItemIdentifier("default-opacity")
        alpha.onChange = { [weak self] raw, finished in
            guard finished else { return }
            self?.writeWidgetSetting("DefaultAlphaValue", value: raw, undoName: "Change Opacity for New Installs",
                                     toast: "New installs start at \(Int(((Double(raw) ?? 255) / 255 * 100).rounded()))% opacity")
        }
        defaults.append(InspectorRow(label: pageLabel("Opacity", key: "DefaultAlphaValue"), control: alpha))
        // The other settings a new install starts with show when the widget sets them (P4, P11: never hidden in the
        // code only) — "Copy My Current Settings" sets the first two.
        if value("DefaultSnapEdges") != nil {
            defaults.append(defaultFlag("DefaultSnapEdges", "Snap to screen edges and other widgets", inverted: false, default: true))
        }
        if value("DefaultKeepOnScreen") != nil {
            defaults.append(defaultFlag("DefaultKeepOnScreen", "Keep on screen", inverted: false, default: true))
        }
        if value("DefaultSavePosition") != nil {
            defaults.append(defaultFlag("DefaultSavePosition", "Remember its position", inverted: false, default: true))
        }
        if value("DefaultStartHidden") != nil {
            defaults.append(defaultFlag("DefaultStartHidden", "Start hidden", inverted: false, default: false))
        }
        if value("DefaultOnHover") != nil {
            let current = Int(value("DefaultOnHover").flatMap { OptionValue.number($0.resolved) } ?? 0)
            let hover = choices(WidgetPresets.onHover, current: current, title: { "\($0)" }, identifier: "default-on-hover") { [weak self] v in
                let title = WidgetPresets.onHover.first { $0.value == v }?.title.lowercased() ?? ""
                self?.writeWidgetSetting("DefaultOnHover", value: String(v), undoName: "Change Pointer Behavior for New Installs",
                                         toast: "New installs, when pointed at: \(title)")
            }
            defaults.append(InspectorRow(label: pageLabel("When the pointer is over it", key: "DefaultOnHover"), control: hover))
        }
        if let written = value("DefaultFadeDuration") {
            let ms = Int(OptionValue.number(written.resolved) ?? 250)
            let fade = NumberControl(value: WidgetPresets.fadeSeconds(ms), placeholder: "0.25", min: 0, max: 10, step: nil,
                                     unit: "seconds", fallback: 0.25, fieldWidth: 44)
            fade.identifier = NSUserInterfaceItemIdentifier("default-fade-time")
            fade.onCommit = { [weak self] v in
                guard let seconds = Double(v) else { return }
                let ms = Int((seconds * 1000).rounded())
                self?.writeWidgetSetting("DefaultFadeDuration", value: String(ms), undoName: "Change Fade Time for New Installs",
                                         toast: "New installs fade in \(WidgetPresets.fadeSeconds(ms)) seconds")
            }
            defaults.append(InspectorRow(label: pageLabel("Fade time", key: "DefaultFadeDuration"), control: fade))
        }
        views.append(EditorStyle.grid(defaults))
        let copy = NSButton(title: "Copy My Current Settings", target: nil, action: nil)
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.identifier = NSUserInterfaceItemIdentifier("copy-current-settings")
        copy.isEnabled = controller != nil
        copy.onAction { [weak self] _ in self?.copyCurrentSettingsToDefaults() }
        views.append(EditorStyle.hstack([copy, EditorStyle.spacer()], spacing: 0))

        // Group names.
        views.append(heading("Group names"))
        let group = ValueField(value("Group")?.raw ?? "", placeholder: "e.g. Clocks", monospaced: false)
        group.identifier = NSUserInterfaceItemIdentifier("widget-group")
        group.toolTip = "Used by actions that change several widgets at once"
        group.onCommit = { [weak self] v in
            guard let self, !self.inspectorState.isRebuilding else { return }
            self.writeWidgetSetting("Group", value: v.isEmpty ? nil : v, undoName: "Change Group Names", toast: "Group names changed")
        }
        views.append(group)
        views.append(caption("e.g. Clocks — used by actions that change several widgets at once.", color: .tertiaryLabelColor))

        // Other shared values.
        let others = index.values.filter { v in
            guard v.variableName != nil, v.kind == .other || v.kind == .font && v.uses.isEmpty, !v.uses.isEmpty else { return false }
            return app.state.editor.showIniNames || !v.isInternal
        }
        if !others.isEmpty {
            views.append(heading("Other shared values"))
            if others.contains(where: { if case .shared = $0.origin { return true } else { return false } }) {
                let name = ManageModel.metadataValue(skin.metadata, "Name") ?? String(skin.config.split(separator: "\\").last ?? "")
                views.append(caption(appliesToAllWidgets
                                     ? "Values shared with other widgets change them all — see Apply to, under Colors and Fonts."
                                     : "Only \(name) changes — see Apply to, under Colors and Fonts.",
                                     color: .tertiaryLabelColor, identifier: "other-values-reach"))
            }
            var items: [InspectorRow] = []
            for v in others {
                guard let name = v.variableName else { continue }
                let words = ValueUsageIndex.humanizedVariable(name)
                let write: (String) -> Void = { [weak self] value in
                    guard let self, !self.inspectorState.isRebuilding else { return }
                    self.writeSharedValues([(name, value)], undoName: "Change \(Self.titleCase(words))", toast: "\(words) changed")
                }
                let control = sharedValueControl(name: name, words: words, value: v, write: write)
                control.identifier = NSUserInterfaceItemIdentifier("shared-value:\(name)")
                items.append(InspectorRow(label: control is CheckboxRow ? nil : pageLabel(words, key: name), control: control))
            }
            views.append(EditorStyle.grid(items))
        }

        // Colors other widgets use: changed where they are defined, for every widget (this one doesn't use them).
        let otherColors = index.colorsOtherWidgetsUse()
        if !otherColors.isEmpty {
            let colorsID = "widget/other-colors"
            let colorsOpen = isDisclosureOpen(colorsID)
            views.append(disclosureHeader("Colors Other Widgets Use (\(otherColors.count))", id: colorsID, summary: "",
                                          open: colorsOpen))
            if colorsOpen {
                let files = otherColors.compactMap(\.file)
                let reach = sharedReach(files)
                views.append(caption("This widget doesn't use them. Changing one changes it in all \(reach?.count ?? 1) "
                                     + "\(skin.rootConfig) widgets.", color: .tertiaryLabelColor, identifier: "other-colors-note"))
                for (i, v) in otherColors.enumerated() {
                    guard let color = v.color else { continue }
                    views.append(colorRow(ValueUsageIndex.ColorGroup(color: color, members: [v]), index: 1000 + i, otherWidgets: true))
                }
            }
        }
        return disclosureCard(id, views: views)
    }

    /// A shared value that is not a color, a size or a font, as a control that shows what it means (§8.1.5 "example
    /// pop-ups"): a date format by an example date, the first day of the week by its name, a 12- or 24-hour clock, a
    /// yes/no value as a checkbox, a number as a number; anything else as text.
    func sharedValueControl(name: String, words: String, value v: ValueUsageIndex.Value, write: @escaping (String) -> Void)
        -> NSView {
        let lower = name.lowercased()
        let current = v.current.trimmingCharacters(in: .whitespaces)
        let calculated = v.raw.contains("#") || v.raw.contains("[")
        func popup(_ items: [(title: String, value: String)], selected: String) -> NSPopUpButton {
            let p = NSPopUpButton()
            for item in items {
                p.addItem(withTitle: item.title)
                p.lastItem?.representedObject = item.value
            }
            p.selectItem(at: items.firstIndex { $0.value == selected } ?? 0)
            p.onAction { c in
                guard let value = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, value != selected else { return }
                write(value)
            }
            return p
        }
        if !calculated, lower.contains("week"), lower.contains("start") || lower.contains("first"), let day = Int(current),
           (0...6).contains(day) {
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return popup(days.enumerated().map { ($1, String($0)) }, selected: current)
        }
        if !calculated, lower.contains("hour"), current == "12" || current == "24" {
            return popup([("24-hour (14:05)", "24"), ("12-hour (2:05 PM)", "12")], selected: current)
        }
        if !calculated, current == "0" || current == "1",
           ["show", "use", "hide", "enable", "is", "has", "display"].contains(where: { lower.hasPrefix($0) }) {
            let box = CheckboxRow(title: words, width: EditorStyle.minimumControlWidth + EditorStyle.labelColumnWidth)
            box.box.state = current == "1" ? .on : .off
            box.box.onAction { b in write((b as? NSButton)?.state == .on ? "1" : "0") }
            return box
        }
        if v.raw.contains("%") {
            // Examples of the date as each format shows it; Custom… for the format as written.
            let example = { (f: String) in
                TimeFormatting.format(Date(timeIntervalSince1970: 1_790_000_000), format: f,
                                      timeZone: TimeZone(identifier: "UTC") ?? .current, locale: Locale(identifier: "en_US_POSIX"))
            }
            let id = "widget/format/\(name)"
            if inspectorState.disclosures.contains(id) {
                let format = FormatControl(value: v.raw, placeholder: "", presets: EditorSchema.timeFormats, render: example)
                format.onCommit = { [weak self] f in
                    self?.inspectorState.disclosures.remove(id)
                    write(f)
                }
                return format
            }
            let timeCodes = ["%H", "%I", "%M", "%S", "%p", "%T", "%X", "%r", "locale-time"]
            let isTime = timeCodes.contains { v.raw.contains($0) }
            let presets = EditorSchema.timeFormats.filter { f in timeCodes.contains { f.contains($0) } == isTime }
            var items = [(title: example(v.raw), value: v.raw)]
            for f in presets where f != v.raw && !items.contains(where: { $0.title == example(f) }) { items.append((example(f), f)) }
            let p = popup(items, selected: v.raw)
            p.menu?.addItem(.separator())
            p.addItem(withTitle: "Custom…")
            p.lastItem?.representedObject = "custom"
            p.onAction { [weak self] c in
                guard let value = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, value != v.raw else { return }
                if value == "custom" {
                    self?.inspectorState.disclosures.insert(id)
                    self?.rebuildKeepingScroll()
                    return
                }
                write(value)
            }
            p.toolTip = app.state.editor.showIniNames ? v.raw : nil
            return p
        }
        if !calculated, let number = Double(current) {
            let field = NumberControl(value: current, placeholder: "", min: nil, max: nil, step: 1, unit: nil, fallback: number,
                                      fieldWidth: 52)
            field.onCommit = write
            field.onStep = { value, finished in if finished { write(value) } }
            return field
        }
        let field = ValueField(v.raw, placeholder: lower.contains("locale") || lower.contains("language") ? "English" : "",
                               monospaced: false)
        field.onCommit = write
        return field
    }

    /// One item of the widget's right-click menu (§8.1.5): "“Open Activity Monitor” → Opens “Activity Monitor”", with
    /// Edit — its name, what it does (Reloads the widget · Opens a website…), Remove — and Edit in Code ›. A name built
    /// from shared values is edited in the code only (P11).
    func menuItemViews(_ n: Int, item: (title: Row, action: Row?), all: [(title: Row, action: Row?)]) -> [NSView] {
        let titleKey = n == 1 ? "ContextTitle" : "ContextTitle\(n)"
        let actionKey = n == 1 ? "ContextAction" : "ContextAction\(n)"
        let action = item.action?.resolved ?? ""
        var views: [NSView] = [caption("“\(item.title.resolved)” → \(Self.actionSentence(action))", identifier: "menu-item:\(n)")]
        let id = "widget/menu-item/\(n)"
        let editable = !item.title.raw.contains("#") && !item.title.raw.contains("[")
        let open = editable && inspectorState.disclosures.contains(id)
        let edit = pageLink(open ? "Done" : "Edit")
        edit.identifier = NSUserInterfaceItemIdentifier("edit-menu-item:\(n)")
        edit.onAction { [weak self] _ in
            guard let self else { return }
            if open { self.inspectorState.disclosures.remove(id) } else { self.inspectorState.disclosures.insert(id) }
            self.rebuildKeepingScroll()
        }
        let code = pageLink("Edit in Code ›")
        code.onAction { [weak self] _ in self?.showInCode(item.title.location) }
        views.append(EditorStyle.hstack(editable ? [edit, code, EditorStyle.spacer()] : [code, EditorStyle.spacer()], spacing: 10))
        guard open else { return views }

        let name = ValueField(item.title.raw, placeholder: "Name in the menu", monospaced: false)
        name.identifier = NSUserInterfaceItemIdentifier("menu-item-name:\(n)")
        name.onCommit = { [weak self] v in
            guard let self, !self.inspectorState.isRebuilding, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.writeWidgetSetting(titleKey, value: v, undoName: "Rename Menu Item", toast: "Menu item renamed “\(v)”")
        }
        let kind = WidgetPresets.menuAction(item.action?.raw ?? "")
        let showsAddress: Bool
        if case .website = kind { showsAddress = true } else { showsAddress = inspectorState.disclosures.contains(id + "/website") }
        let does = NSPopUpButton()
        does.identifier = NSUserInterfaceItemIdentifier("menu-item-action:\(n)")
        if kind == .other {
            does.addItem(withTitle: Self.actionSentence(action))
            does.lastItem?.representedObject = "keep"
        }
        does.addItem(withTitle: "Reloads the widget")
        does.lastItem?.representedObject = "reload"
        does.addItem(withTitle: "Opens a website…")
        does.lastItem?.representedObject = "website"
        does.menu?.addItem(.separator())
        does.addItem(withTitle: "Edit in Code…")
        does.lastItem?.representedObject = "code"
        switch kind {
        case .reload where !showsAddress: does.selectItem(at: does.indexOfItem(withRepresentedObject: "reload"))
        case .other where !showsAddress: does.selectItem(at: 0)
        default: does.selectItem(at: does.indexOfItem(withRepresentedObject: "website"))
        }
        does.onAction { [weak self] c in
            guard let self, let chosen = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            switch chosen {
            case "reload":
                self.inspectorState.disclosures.remove(id + "/website")
                self.writeWidgetSetting(actionKey, value: "[!Refresh]", undoName: "Change Menu Item",
                                        toast: "The menu item reloads the widget")
            case "website":
                self.inspectorState.disclosures.insert(id + "/website")
                self.rebuildKeepingScroll()
            case "code":
                self.showInCode(item.action?.location ?? item.title.location)
            default:
                break
            }
        }
        var rows = [InspectorRow(label: pageLabel("Name", key: titleKey), control: name),
                    InspectorRow(label: pageLabel("When chosen", key: actionKey), control: does)]
        if showsAddress {
            var current = ""
            if case .website(let url) = kind { current = url }
            let address = ValueField(current, placeholder: "example.com", monospaced: false)
            address.identifier = NSUserInterfaceItemIdentifier("menu-item-address:\(n)")
            address.onCommit = { [weak self] v in
                guard let self, !self.inspectorState.isRebuilding else { return }
                var url = v.trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty else { return }
                if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") { url = "https://" + url }
                self.inspectorState.disclosures.remove(id + "/website")
                self.writeWidgetSetting(actionKey, value: "[\"\(url)\"]", undoName: "Change Menu Item",
                                        toast: "The menu item \(Self.actionSentence("[\"\(url)\"]").lowercased())")
            }
            rows.append(InspectorRow(label: pageLabel("Address", key: nil), control: address))
        }
        views.append(EditorStyle.grid(rows))
        let remove = NSButton(title: "Remove Item", target: nil, action: nil)
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.identifier = NSUserInterfaceItemIdentifier("remove-menu-item:\(n)")
        remove.onAction { [weak self] _ in self?.removeMenuItem(n, all: all) }
        views.append(EditorStyle.hstack([remove, EditorStyle.spacer()], spacing: 0))
        return views
    }

    /// Removes item `n` (1-based) of the right-click menu; the items after it move up, since the engine ignores every
    /// item after a missing one (one undo step).
    func removeMenuItem(_ n: Int, all: [(title: Row, action: Row?)]) {
        guard n >= 1, n <= all.count else { return }
        func key(_ base: String, _ i: Int) -> String { i == 1 ? base : "\(base)\(i)" }
        var writes: [(key: String, value: String?)] = []
        for i in n..<all.count {
            writes.append((key("ContextTitle", i), all[i].title.raw))
            writes.append((key("ContextAction", i), all[i].action?.raw))
        }
        writes.append((key("ContextTitle", all.count), nil))
        writes.append((key("ContextAction", all.count), nil))
        inspectorState.disclosures = inspectorState.disclosures.filter { !$0.hasPrefix("widget/menu-item/") }
        writeWidgetSettings(writes, undoName: "Remove Menu Item",
                            toast: "Removed “\(all[n - 1].title.resolved)” from the right-click menu")
    }

    /// "When someone else installs it" takes this Mac's desktop settings (one undo step).
    func copyCurrentSettingsToDefaults() {
        guard let c = controller else { return }
        let s = c.state
        writeWidgetSettings([("DefaultAlwaysOnTop", String(s.alwaysOnTop)), ("DefaultDraggable", s.draggable ? "1" : "0"),
                             ("DefaultClickThrough", s.clickThrough ? "1" : "0"), ("DefaultAlphaValue", String(s.alphaValue)),
                             ("DefaultSnapEdges", s.snapEdges ? "1" : "0"), ("DefaultKeepOnScreen", s.keepOnScreen ? "1" : "0")],
                            undoName: "Copy My Current Settings", toast: "New installs start the way it is on this Mac")
    }

    /// An action in words: "Opens “Activity Monitor”", "Opens example.com", "Reloads the widget", "Runs 2 commands".
    static func actionSentence(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "Nothing" }
        let actions = ActionParser.parse(t)
        guard !actions.isEmpty else { return "Runs an action from a shared value" }
        guard actions.count == 1 else { return "Runs \(actions.count) commands" }
        switch actions[0] {
        case .execute(let target, _):
            let cleaned = target.replacingOccurrences(of: "\\", with: "/")
            if let url = URL(string: cleaned), let host = url.host, url.scheme?.lowercased().hasPrefix("http") == true {
                return "Opens \(host)"
            }
            let base = ((cleaned as NSString).lastPathComponent as NSString).deletingPathExtension
            return "Opens “\(base.isEmpty ? cleaned : base)”"
        case .bang(let bang):
            return bang.name == "refresh" ? "Reloads the widget" : "Runs a command"
        }
    }

    // MARK: The widget's own sections

    /// `[Variables]`, `[Rainmeter]` or `[Metadata]` selected (from the code): the shared values as written, the widget
    /// page, its details.
    func widgetSectionPage(_ name: String, kind: InspectedSectionKind?, skin: Skin) {
        switch kind {
        case .variables?:
            add(header(title: "Shared Values", subtitle: "What the widget's layers share, as written in its files",
                       symbol: "paintpalette", location: skin.sources.location(section: "Variables")))
            add(variablesCard(rows))
        case .rainmeter?:
            skinOverview(skin)
        case .metadata?:
            add(header(title: "About This Widget", subtitle: "Shown in Manage Widgets", symbol: "info.circle",
                       location: skin.sources.location(section: name)))
            if let card = groupCard(EditorSchema.aboutGroup, groups: [EditorSchema.aboutGroup], section: name, rows: rows,
                                    force: true) { add(card) }
            add(otherOptionsCard(section: name, rows: rows, groups: [EditorSchema.aboutGroup], open: advancedOpen))
        default:
            break
        }
    }

    // MARK: Shared values as written

    /// `[Variables]` (reached from the code): colors (with swatches) first, then the rest, by their names.
    func variablesCard(_ rows: [Row], title: String = "Shared values") -> NSView {
        let isColor: (Row) -> Bool = { (OptionValue.color($0.resolved) != nil && $0.raw.contains(",")) || EditorStyle.isColorKey($0.key) }
        let ordered = rows.filter(isColor) + rows.filter { !isColor($0) }
        let items: [InspectorRow] = ordered.map { r in
            let p = EditorSchema.Property(r.key, r.key, isColor(r) ? .color : .text)
            let row = Row(key: r.key, raw: r.raw, resolved: r.resolved, source: r.source, sourceTip: r.sourceTip,
                          location: r.location, style: .own)
            let ctx = PropertyContext(property: p, section: "Variables", key: r.key, row: row, variable: nil, form: .literal)
            var lines: [NSView] = []
            let control = kindControl(ctx, lines: &lines)
            if control.identifier == nil { control.identifier = NSUserInterfaceItemIdentifier(r.key) }
            let label = EditorStyle.rowLabel(r.key, key: nil, tooltip: r.key + (r.sourceTip.isEmpty ? "" : "\n" + r.sourceTip),
                                             identifier: true)
            attach(rowMenu(ctx), to: label)
            var cell: NSView = control
            if r.resolved != r.raw, !isColor(r) {
                let now = EditorStyle.mono("= " + r.resolved, size: 10.5)
                now.toolTip = r.resolved
                let stack = EditorStyle.vstack([control, now], spacing: 3)
                control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                now.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
                cell = stack
            }
            return InspectorRow(label: label, control: cell)
        }
        var views: [NSView] = [cardNote("Change one and every layer using it follows.")]
        if !items.isEmpty { views.append(EditorStyle.grid(items)) }
        if selectedKind == .variables { views.append(addRow()) }
        return EditorCard(title: title, views: views)
    }
}

/// A row of the widget page that outlines who uses its value while the pointer is over it (§8.1.1 "Hovering a row
/// pulses the users' outlines").
final class ValueRowView: NSView {
    /// The color the row changes (nil for a font row).
    var group: ValueUsageIndex.ColorGroup?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
