import Foundation

/// Base class of all meters: position/size (with `r`/`R` relative positioning, Padding and Container), Hidden,
/// SolidColor background, MeterStyle, bound measures, mouse actions and tooltips.
///
/// Clean-room implementation of the public manual only (/manual/meters/, /manual/meters/general-options/ and its
/// sub-pages container, meterstyles, tooltips; /manual/mouse-actions/). Rules:
/// - `X`/`Y` (default 0) are relative to the skin's top-left corner; `r` = relative to the previous meter's X/Y,
///   `R` = relative to its X+W / Y+H. "Previous" is the previous meter in the file, hidden meters included (a hidden
///   meter "still exists and occupies a position in space", with W and H of zero).
/// - The previous meter's X / Y here is its *anchor*: the position its X / Y options resolved to, before
///   `StringAlign` (String) or `BitmapAlign` (Bitmap) moved its box. "StringAlign … is always based on the value of
///   X or Y", and skins rely on the following meter being relative to that value: eClock's long shadow (20+
///   right-aligned copies at `X=1r Y=1r`, each one pixel right of and below the previous anchor), EasyInfo's LED text
///   (`X=0r` over a centered backlight must overlap it exactly), Enigma's System labels (a right-aligned label, its
///   value at `X=9r`), and FluentDash11's settings rows (`Y=17R` after a CenterCenter button caption: the rows in
///   the author's screenshot are 64 px apart, i.e. anchor + H + 17 — the moved box would give 50). `R` therefore
///   adds W / H to the anchor, not to the moved box. `[Meter:X]` / `[Meter:Y]` still report the moved box ("The
///   values for X or Y may be different than the values in the meter options if StringAlign is used").
/// - `W`/`H`: when missing, meters that can size themselves (String, Image, Shape…) use `naturalSize()`, others 0.
/// - `Padding=L,T,R,B` is added to W/H ("the width and height of the meter will dynamically be adjusted"), so
///   `[Meter:W]` includes it; the content starts at X+L, Y+T. Judgment: missing trailing values count as 0.
/// - `Hidden=1`: "done by setting the width and height of the meter to zero".
/// - `Container=Meter`: the meter becomes content of that container (see `Skin.layout()`): the first content meter
///   is positioned relative to the container's top-left ("r is assumed and R is ignored"), later content meters are
///   relative to each other, and meters that are not content are relative to the previous non-content meter.
///   Containers may not be nested: a `Container` naming the meter itself or a meter that has a `Container` option
///   of its own is ignored (with a log line). The host draws content clipped/masked by its container and does not
///   draw the container itself (`isContainer`).
/// - `TransformationMatrix` changes only the drawing: the untransformed frame still defines the window size and
///   mouse hit area.
/// - Mouse actions are read as action options; `OnUpdateAction` runs each time the meter is updated. The mouse is
///   detected where `hitTest(x:y:)` says so: the frame for most meters, "any solid part" of the shapes for Shape
///   meters (manual: Shape → Mouse Detection on Shapes), the non-transparent pixels for Button meters.
/// - Judgment (the manual gives no limits): X, Y, W, H and the final frame are finite and within ±`maxCoordinate`
///   points, so a skin whose formulas explode never hands huge values to the host.
open class Meter: SkinSection {
    /// Lowercased `Meter=` value.
    public let type: String

    /// Final rectangle (padding included) in skin coordinates, computed by `layout(after:)`. This is the "real"
    /// box that `[Meter:X]`, `[Meter:W]`… report.
    public internal(set) var frame = SkinRect()
    /// The resolved X / Y position before alignment (skin coordinates): the anchor of an aligned String
    /// (`StringAlign`) or Bitmap (`BitmapAlign`) meter, otherwise the frame's top-left corner. The next meter's
    /// `r` / `R` positions are relative to it (see the type documentation).
    public internal(set) var anchorX = 0.0
    public internal(set) var anchorY = 0.0
    public internal(set) var hidden = false
    public internal(set) var solidColor = RGBA.clear
    public internal(set) var solidColor2: RGBA?
    public internal(set) var gradientAngle = 0.0
    public internal(set) var bevelType = 0
    /// `BevelColor` / `BevelColor2` (nil = the default light / dark bevel colors).
    public internal(set) var bevelColor: RGBA?
    public internal(set) var bevelColor2: RGBA?
    public internal(set) var padding = SkinInsets.zero
    public internal(set) var antiAlias = false
    /// The measures found for `MeasureName`, `MeasureName2`… in order, without gaps (kept for compatibility; a name
    /// that names no measure is left out, so positions shift — use `measureSlots` for `%N`).
    public internal(set) var measures: [Measure] = []
    /// `MeasureNameN` → slot N−1: the bound measure, or nil when that option is missing, empty or names no measure.
    /// Index-aligned with the option numbers, so `%2` always means `MeasureName2`.
    public internal(set) var measureSlots: [Measure?] = []
    public internal(set) var mouseActions: [MouseEventKind: String] = [:]
    public internal(set) var toolTipText = ""
    public internal(set) var toolTipTitle = ""
    public internal(set) var toolTipIcon = ""
    /// `ToolTipType=1`: balloon tooltip.
    public internal(set) var toolTipBalloon = false
    public internal(set) var toolTipWidth = 1000.0
    public internal(set) var toolTipHidden = false
    /// `MouseActionCursor` (default from `[Rainmeter]`, itself default 1): show a pointer over mouse actions.
    public internal(set) var mouseActionCursor = true
    /// `MouseActionCursorName`: a cursor file in `@Resources/Cursors` or a built-in name (`HAND`, `TEXT`…).
    public internal(set) var mouseActionCursorName = ""
    /// `TransformationMatrix=a;b;c;d;tx;ty`.
    public internal(set) var transformationMatrix: [Double]?
    /// The meter this meter is content of (`Container=`), after validation.
    public internal(set) weak var container: Meter?
    /// True when some other meter uses this meter as its container: the host must not draw it, only use it to
    /// clip / mask its content.
    public internal(set) var isContainer = false

    var xPosition = PositionValue(value: 0)
    var yPosition = PositionValue(value: 0)
    var widthOption: Double?
    var heightOption: Double?
    /// `Container=` as written (resolved to `container` by the skin's layout).
    var containerName = ""
    var onUpdateAction = ""
    /// The Hidden option text last applied; `!ShowMeter`/`!HideMeter` state lasts until it changes (or until
    /// `!SetOption … Hidden` sets it again).
    var lastHiddenOption: String?
    /// `MeasureNameN=Name` texts already reported as naming no measure (dynamic meters re-read the option on every
    /// update; bounded so a changing name cannot grow it forever).
    private var reportedMissingMeasures: Set<String> = []

    /// Distinct missing `MeasureNameN` texts reported per meter.
    static let maxReportedMissingMeasures = 64

    /// Largest magnitude (points) of X, Y, W, H and of the final frame — see the type documentation.
    public static let maxCoordinate = 1_000_000.0

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        self.type = type
        super.init(name: name, section: section, skin: skin)
    }

    /// Content area (frame minus padding).
    public var contentFrame: SkinRect {
        SkinRect(x: frame.x + padding.left, y: frame.y + padding.top,
                 width: max(frame.width - padding.left - padding.right, 0),
                 height: max(frame.height - padding.top - padding.bottom, 0))
    }

    public var hasMouseActions: Bool { !mouseActions.isEmpty }

    /// The action to run for `kind`: nil when not defined or cleared (the event passes through to meters / the skin
    /// behind), `""` when disabled (the event is caught but nothing runs), otherwise the action.
    public func effectiveMouseAction(_ kind: MouseEventKind) -> String? {
        guard let action = mouseActions[kind] else { return nil }
        switch mouseActionState(kind) {
        case .enabled: return action
        case .disabled: return ""
        case .cleared: return nil
        }
    }

    /// Whether the mouse is over this meter at the point (skin coordinates), ignoring Hidden and Container (see
    /// `isHit`): the frame rectangle. Shape meters detect the mouse on the solid parts of their shapes, Button meters
    /// react themselves (ButtonCommand, button states) on the non-transparent pixels of their image.
    open func hitTest(x: Double, y: Double) -> Bool {
        frame.contains(x: x, y: y)
    }

    /// Visible, not hidden by its container, and hit at the point (skin coordinates): where the meter's mouse actions,
    /// hover actions, tooltip and cursor apply. Every mouse lookup of the skin uses this. It is `hitTest`, except for
    /// a meter that handles the mouse itself (Button): its general mouse actions use the frame, and only its own
    /// reaction (`handleMouse`, `isHit(x:y:precise: true)`) follows `hitTest` — manual (Button): "ButtonCommand
    /// ignores transparent pixels in the image at all times, where LeftMouseUpAction will only ignore clicks on
    /// transparent areas if there is not some other meter behind the image" (the window itself lets clicks on fully
    /// transparent pixels through). Content outside its container "in effect doesn't exist", also for the mouse: the
    /// container must be visible and hit (`hitTest`) there too.
    public func isHit(x: Double, y: Double) -> Bool {
        isHit(x: x, y: y, precise: !handlesMouseItself)
    }

    /// `isHit` with the meter's own area: `hitTest` when `precise`, otherwise the frame rectangle.
    public func isHit(x: Double, y: Double, precise: Bool) -> Bool {
        guard !hidden, precise ? hitTest(x: x, y: y) : frame.contains(x: x, y: y) else { return false }
        if let container {
            return !container.hidden && container.hitTest(x: x, y: y)
        }
        return true
    }

    // MARK: Subclass hooks

    /// Reads type-specific options (called after the common options).
    open func readMeterOptions() {}

    /// Pulls fresh values from the bound measures.
    open func updateMeter() {}

    /// Natural content size used when `W` / `H` are not given (text extent, image size…).
    open func naturalSize() -> (width: Double, height: Double) { (0, 0) }

    /// Called before a provisional layout (`Skin.ensureMeterGeometry`, before the first update has laid the meters
    /// out) so `naturalSize()` has something to measure. Most meters know their size from their options already;
    /// String meters compose their text once if they have not been updated yet. Must not have side effects that an
    /// update would not have (no graph samples, no transitions).
    open func prepareProvisionalLayout() {}

    /// Offset applied to the anchor position (String meters shift for StringAlign=Right/Center…).
    open func anchorOffset(width: Double, height: Double) -> (dx: Double, dy: Double) { (0, 0) }

    /// Meters that react to the mouse themselves (Button) return true; they get `handleMouse` first.
    open var handlesMouseItself: Bool { false }

    /// Mouse event on this meter (skin coordinates). Return true when consumed.
    open func handleMouse(_ kind: MouseEventKind, x: Double, y: Double) -> Bool { false }

    /// Hover tracking for `handlesMouseItself` meters (called on every mouse move and on exit).
    open func mouseHover(inside: Bool, x: Double, y: Double) {}

    // MARK: Options

    open override func readOptions() {
        // MeterStyle is read from the meter itself (and !SetOption), never from styles.
        let styleOption: String
        if let override = overrides["meterstyle"] {
            styleOption = override
        } else {
            styleOption = own.value(forKey: "MeterStyle") ?? ""
        }
        let styleSectionVariables = bool("DynamicVariables", false) || readingAfterLoad
        let styleText = skin.resolve(styleOption, in: self, sectionVariables: styleSectionVariables)
        styles = OptionValue.list(styleText)
        // `MeterStyle=A | B[MeasureX]` read without section variables (the load-time read of a section without
        // DynamicVariables in the meter itself): read once more at the first update, like any other option.
        if !styleSectionVariables, !mentionsSectionVariables, styleText.utf8.contains(UInt8(ascii: "[")) {
            mentionsSectionVariables = skin.mentionsSectionVariable(styleText)
        }
        reportMissingStyles(styleOption, sectionVariablesResolved: styleSectionVariables)

        super.readOptions()

        xPosition = Meter.position(option("X"))
        yPosition = Meter.position(option("Y"))
        widthOption = Meter.size(optionalDouble("W"))
        heightOption = Meter.size(optionalDouble("H"))

        let hiddenOption = string("Hidden", "0")
        if hiddenOption != lastHiddenOption {
            lastHiddenOption = hiddenOption
            hidden = OptionValue.bool(hiddenOption) ?? false
        }

        solidColor = color("SolidColor", .clear)
        solidColor2 = option("SolidColor2").flatMap(OptionValue.color)
        gradientAngle = double("GradientAngle", 0)
        bevelType = int("BevelType", 0)
        bevelColor = option("BevelColor").flatMap(OptionValue.color)
        bevelColor2 = option("BevelColor2").flatMap(OptionValue.color)
        let p = OptionValue.numbers(string("Padding")).map { $0.clamped(-Meter.maxCoordinate, Meter.maxCoordinate) }
        func pad(_ i: Int) -> Double { i < p.count ? p[i] : 0 }
        padding = p.isEmpty ? .zero : SkinInsets(left: pad(0), top: pad(1), right: pad(2), bottom: pad(3))
        antiAlias = bool("AntiAlias", false)
        containerName = string("Container").trimmingCharacters(in: .whitespaces)

        readMeasureSlots()

        // An empty value means "no action" (not detected); `[]` is an action that does nothing but is detected.
        var actions: [MouseEventKind: String] = [:]
        for kind in MouseEventKind.allCases {
            let a = actionOption(kind.rawValue)
            if !a.trimmingCharacters(in: .whitespaces).isEmpty { actions[kind] = a }
        }
        mouseActions = actions
        onUpdateAction = actionOption("OnUpdateAction")

        toolTipText = string("ToolTipText")
        toolTipTitle = string("ToolTipTitle")
        toolTipIcon = string("ToolTipIcon").trimmingCharacters(in: .whitespaces)
        toolTipBalloon = bool("ToolTipType", false)
        toolTipWidth = double("ToolTipWidth", 1000).clamped(1, 1e5)
        toolTipHidden = bool("ToolTipHidden", false)
        mouseActionCursor = bool("MouseActionCursor", skin.settings.mouseActionCursor)
        mouseActionCursorName = string("MouseActionCursorName", skin.settings.mouseActionCursorName)
            .trimmingCharacters(in: .whitespaces)

        // "There must be exactly 6 values separated by semicolons".
        let parts = string("TransformationMatrix").split(separator: ";", omittingEmptySubsequences: false)
        let matrix = parts.compactMap { OptionValue.number(String($0).trimmingCharacters(in: .whitespaces)) }
        transformationMatrix = parts.count == 6 && matrix.count == 6 && matrix.allSatisfy({ $0.isFinite })
            ? matrix : nil

        readMeterOptions()
    }

    /// Logs the MeterStyle names that name no section — an authoring mistake that behaves the same in Rainmeter, so a
    /// log line (once per name), not a compatibility issue.
    ///
    /// A name built from a section variable (`StyleGrabber[MeasureActive1]`, Enigma's Reader and Notes grabbers)
    /// cannot be checked before section variables have real values: at the load-time read they are either not
    /// resolved (the name still reads `StyleGrabber[MeasureActive1]`, e.g. when DynamicVariables=1 comes from a
    /// style, which is not known yet) or resolved before any measure has updated. Such names are checked from the
    /// first read after the skin loaded that resolves section variables (the first update); names written without
    /// section variables are checked right away.
    private func reportMissingStyles(_ styleOption: String, sectionVariablesResolved: Bool) {
        var missing = styles.filter { skin.styleSection(named: $0) == nil }
        guard !missing.isEmpty else { return }
        if !(sectionVariablesResolved && skin.optionsLoaded), styleOption.utf8.contains(UInt8(ascii: "[")) {
            let written = OptionValue.list(skin.resolve(styleOption, in: self, sectionVariables: false))
            let pending = written.filter { $0.utf8.contains(UInt8(ascii: "[")) && skin.mentionsSectionVariable($0) }
            if !pending.isEmpty {
                let settled = Set(written.filter { !pending.contains($0) }.map { $0.lowercased() })
                missing = missing.filter { settled.contains($0.lowercased()) }
            }
        }
        for style in missing {
            skin.logOnce("MeterStyle \"\(style)\" used by [\(name)] does not exist", level: .warning)
        }
    }

    /// `MeasureName`, `MeasureName2`… → `measureSlots` (index-aligned) and `measures` (found ones). A name that
    /// names no measure is logged once per meter and name, not on every update of a dynamic meter.
    private func readMeasureSlots() {
        var slots: [Measure?] = []
        for entry in numberedOptions("MeasureName") {
            let measureName = entry.value.trimmingCharacters(in: .whitespaces)
            var found: Measure?
            if !measureName.isEmpty {
                found = skin.measure(named: measureName)
                if found == nil, reportedMissingMeasures.count < Meter.maxReportedMissingMeasures {
                    let option = "MeasureName\(entry.index == 1 ? "" : String(entry.index))=\(measureName)"
                    if reportedMissingMeasures.insert(option.lowercased()).inserted {
                        skin.log("[\(name)] \(option) not found", level: .warning)
                    }
                }
            }
            // `numberedOptions` may skip `MeasureName` itself (1) but has no other gaps.
            while slots.count < entry.index - 1 { slots.append(nil) }
            slots.append(found)
        }
        measureSlots = slots
        measures = slots.compactMap { $0 }
    }

    /// How many bound measures `%1`, `%2`… of the tooltip may use (manual, Tooltips → ToolTipText: "String, Line,
    /// Image: %1, %2, %3, ...", "Histogram: %1, %2", every other meter "%1").
    var toolTipMeasureLimit: Int {
        switch type {
        case "string", "line", "image": return measureSlots.count
        case "histogram": return min(measureSlots.count, 2)
        default: return min(measureSlots.count, 1)
        }
    }

    /// The `ToolTipText` (and `ToolTipTitle`) with `%1`, `%2`… replaced by the bound measures, or nil when there is
    /// no (visible) tooltip. Manual (Tooltips): "On a String meter, numeric formatting options are forced to
    /// AutoScale=1, Scale=1, NumOfDecimals=0, Percentual=0"; judgment: the same for every meter type, and the title
    /// is substituted like the text. `%N` is replaced in one pass (a measure value containing `%1` stays as it is);
    /// a slot whose measure does not exist becomes empty, a number beyond the meter's limit stays literal.
    public var toolTipInfo: ToolTipInfo? {
        guard !toolTipHidden, !toolTipText.isEmpty else { return nil }
        let limit = toolTipMeasureLimit
        func substituted(_ template: String) -> String {
            guard limit > 0, template.utf8.contains(UInt8(ascii: "%")) else { return template }
            let format = NumberFormatOptions(autoScale: .binary(minimumPower: 0), scale: 1, numOfDecimals: 0,
                                             percentual: false)
            return StringMeter.substitute(template, count: limit) { index in
                guard index >= 1, index <= limit, index <= measureSlots.count else { return nil }
                return measureSlots[index - 1]?.text(numberFormat: format) ?? ""
            }
        }
        return ToolTipInfo(text: substituted(toolTipText), title: substituted(toolTipTitle), icon: toolTipIcon,
                           balloon: toolTipBalloon, maxWidth: toolTipWidth)
    }

    // MARK: Layout

    /// Positions the meter after `previous` (the previous meter in file order; for content meters the previous
    /// content meter of the same container) — see the type documentation. `container` is the validated container
    /// for content meters.
    func layout(after previous: Meter?, in container: Meter? = nil) {
        let width: Double, height: Double
        if hidden {
            width = 0
            height = 0
        } else {
            let natural: (width: Double, height: Double) =
                (widthOption == nil || heightOption == nil) ? naturalSize() : (0, 0)
            width = finite((widthOption ?? finite(natural.width)) + padding.left + padding.right)
                .clamped(0, Meter.maxCoordinate)
            height = finite((heightOption ?? finite(natural.height)) + padding.top + padding.bottom)
                .clamped(0, Meter.maxCoordinate)
        }

        func resolve(_ p: PositionValue, origin: Double, start: Double?, end: Double?) -> Double {
            switch p.mode {
            case .absolute: return origin + p.value
            case .relativeToPreviousStart: return (start ?? origin) + p.value
            // The first content meter: "r is assumed and R is ignored".
            case .relativeToPreviousEnd: return (end ?? start ?? origin) + p.value
            }
        }
        let originX = container?.frame.x ?? 0
        let originY = container?.frame.y ?? 0
        let offset = anchorOffset(width: width, height: height)
        // `r` / `R` use the previous meter's anchor (its X / Y before StringAlign / BitmapAlign moved the box), and
        // `R` adds its W / H to it — not the moved box: see the type documentation.
        let x = resolve(xPosition, origin: originX, start: previous?.anchorX,
                        end: previous.map { $0.anchorX + $0.frame.width })
        let y = resolve(yPosition, origin: originY, start: previous?.anchorY,
                        end: previous.map { $0.anchorY + $0.frame.height })
        anchorX = finite(x)
        anchorY = finite(y)
        frame = SkinRect(x: finite(x + (hidden ? 0 : offset.dx)), y: finite(y + (hidden ? 0 : offset.dy)),
                         width: width, height: height)
    }

    private func finite(_ v: Double) -> Double {
        v.isFinite ? v.clamped(-Meter.maxCoordinate, Meter.maxCoordinate) : 0
    }

    /// `X` / `Y` as read: a missing, unreadable or non-finite value is 0; the offset is within ±`maxCoordinate`.
    static func position(_ text: String?) -> PositionValue {
        guard var p = text.flatMap(OptionValue.position), p.value.isFinite else { return PositionValue(value: 0) }
        p.value = p.value.clamped(-maxCoordinate, maxCoordinate)
        return p
    }

    /// `W` / `H` as read: nil (the natural size) when missing or non-finite, otherwise within 0…`maxCoordinate`.
    static func size(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value.clamped(0, maxCoordinate)
    }

    // MARK: Bangs

    func setHidden(_ flag: Bool) {
        hidden = flag
    }

    // MARK: Helpers

    /// Number formatting options shared by String-like meters: `AutoScale`, `Scale`, `NumOfDecimals` and `Percentual`,
    /// each a number or a formula (`NumOfDecimals=(#Decimals#+1)`, `AutoScale=(#Mode#)`), like the String meter reads
    /// them. Missing or empty options keep the defaults; `Scale` "has a decimal point" when its text has one.
    func numberFormatOptions() -> NumberFormatOptions {
        var nf = NumberFormatOptions()
        if let a = option("AutoScale") { nf.autoScale = Meter.autoScale(a) }
        if let rawScale = option("Scale"), !rawScale.trimmingCharacters(in: .whitespaces).isEmpty {
            if let v = OptionValue.number(rawScale), v.isFinite { nf.scale = v }
            nf.scaleHasDecimalPoint = NumberFormatOptions.scaleHasDecimalPoint(rawScale)
        }
        if let n = optionalDouble("NumOfDecimals"), n.isFinite {
            nf.numOfDecimals = Int(n.clamped(0, 1000).rounded(.towardZero))
        }
        nf.percentual = bool("Percentual", false)
        return nf
    }

    /// `AutoScale`: `1`, `2k`… as written, or a formula whose (whole-number) result is the mode.
    static func autoScale(_ text: String) -> AutoScale {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("("), let n = OptionValue.number(t), n.isFinite, abs(n) < 10 {
            return AutoScale.parse(String(Int(n.rounded(.towardZero))))
        }
        return AutoScale.parse(t)
    }
}

/// Placeholder for meter types not implemented yet; takes up its W/H but draws only its background.
public final class UnsupportedMeter: Meter {}
