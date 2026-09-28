import AppKit
import DesksetCore

/// Where a row's value comes from, always said with an icon and a word (never color alone): an option the widget's
/// author gave it, live data, a rule, a shared style.
enum StudioValueSource: String, Equatable {
    case option, live, rule, style

    var symbol: String {
        switch self {
        case .option: return "slider.horizontal.3"
        case .live: return "dot.radiowaves.left.and.right"
        case .rule: return "arrow.triangle.branch"
        case .style: return "paintbrush"
        }
    }

    var word: String {
        switch self {
        case .option: return StudioText[.sourceOption]
        case .live: return StudioText[.sourceLive]
        case .rule: return StudioText[.sourceRule]
        case .style: return StudioText[.sourceStyle]
        }
    }
}

/// One page of the inspector as data: a title and a sentence, sections of rows, a footer of links. Rows have ids that
/// stay the same from one build of the page to the next, so the view updates them in place (`StudioPageView.apply`).
/// The generator builds a page from the catalog and the widget; `fitted` keeps it within the design's twelve controls.
struct StudioPage: Equatable {
    var id: String
    var title: String
    var subtitle: String
    var sections: [Section] = []
    var footer: [Link] = []
    /// A long page (or one with a confirmation open) uses the tight rhythm between sections.
    var tight = false
    /// The way back, above the title: "‹ System › CPU" (the first goes back to the widget page).
    var crumbs: [String] = []
    /// The scope sentence under the title, before any change: "This number only · Apply to All 4 Numbers".
    var scope: Scope?
    /// A confirmation at the top of the page (a change made on the canvas: a drag).
    var topConfirmation: Confirmation?
    /// What the search field says and does: "What do you want to change?", or "Filter these settings" on Every
    /// Setting (with what is typed in it).
    var filter: Filter?

    struct Filter: Equatable {
        var placeholder: String
        var text: String
    }

    /// The scope sentence: what a change reaches now, and the one-click wider (or narrower) reach.
    struct Scope: Equatable {
        var text: String
        var link: String?
        /// The pointer is on the link (the canvas outlines what it would reach).
        var linkHovered = false
    }

    /// A section: a title with an optional command at its right (A− / A+), then its items.
    struct Section: Equatable {
        var id: String
        var title: String
        var trailing: Trailing?
        var items: [Item]
        /// Every Setting's dense rhythm: a smaller heading, no hairline above it.
        var dense = false
    }

    enum Trailing: Equatable {
        /// A− / A+: every text in the widget smaller or bigger.
        case textSize
        /// Quiet words at the heading's right ("outside → inside").
        case note(String)
    }

    struct Item: Equatable {
        var id: String
        var kind: Kind
    }

    enum Kind: Equatable {
        case row(Row)
        case swatches(Swatches)
        case thumbnails(Thumbnails)
        case link(Link)
        /// A quiet sentence (a scope line), with a link at its end.
        case note(Note)
        case confirmation(Confirmation)
        /// Data and words in one field ("CPU usage %"): the data chip opens what it can show.
        case token(Token)
        /// Examples rendered with the real value, one chosen ("21% · 21.4% · 0.21").
        case examples(Examples)
        /// A row of Every Setting: a small label (that can be dragged to change a number) and a small control.
        case dense(Dense)
        /// The box from outside in: margin, shadow, background, border, padding.
        case box(Box)
    }

    struct Token: Equatable {
        enum Part: Equatable {
            case data(name: String, symbol: String)
            case text(String)
        }
        var parts: [Part]
        var small = false
    }

    struct Examples: Equatable {
        var items: [String]
        var selected: Int?
        var small = false
    }

    struct Dense: Equatable {
        var label: String
        var control: Control
        /// Under the label's row, quieter: which word the filter found it by ("Color · Rainmeter: FontColor").
        var note: String?
        /// The label is being dragged (its value changes): drawn with ↔.
        var scrubbing = false
        var tooltip: String?
    }

    struct Box: Equatable {
        var margin: String
        var shadow: String
        var background: String
        var border: String
        var padding: String
        /// What sits in the middle ("23%").
        var content: String
    }

    /// A label and the control that changes the value.
    struct Row: Equatable {
        var label: String
        var control: Control
        var source: StudioValueSource?
        /// The value as written when it is not one the control can show: shown as it is, with an amber mark.
        var invalid: String?
        /// The INI name, shown in small type at the row's end with Rainmeter details on.
        var detail: String?
        var tooltip: String?
        /// The label column's width (76 pt; narrower where the labels are short: Shows, Size).
        var labelWidth: CGFloat = 76
    }

    enum Control: Equatable {
        case popup(Popup)
        case segmented(Segmented)
        case toggle(Bool)
        /// 0…1, with the percentage beside it.
        case percent(Double)
        /// One color swatch in a row (an option).
        case color(Swatch)
        case text(String)
        /// A number: its field (with its notation kept: `10R`, `(#Gap# + 4)`), its unit, and the shortcuts of every
        /// number field (drag the label, arithmetic, ⌥-click the label for the default, arrows ±1, ⇧ ±10).
        case number(Number)
        /// A swatch with words beside it: "Text color · follows Light / Dark".
        case colorLabel(ColorLabel)
        /// Two controls side by side (Size: W · H; Font · weight).
        case pair([Control])
    }

    struct Number: Equatable {
        /// What the field shows: the value as written ("10R"), or empty with `placeholder` ("Fit").
        var text: String
        var value: Double?
        var unit: String?
        /// Before the number, inside the field ("W", "x").
        var prefix: String?
        var placeholder: String = ""
        /// What ⌥-clicking the label puts back (nil: nothing to reset to).
        var defaultText: String?
        /// A− / A+ beside the field (text sizes).
        var steppers = false
        var width: CGFloat?
        /// Words after the field, quieter ("after “23%”").
        var meaning: String?
        var step: Double = 1
        var minimum: Double?
        var maximum: Double?
    }

    struct ColorLabel: Equatable {
        var swatch: Swatch
        var title: String
        var note: String?
    }

    struct Popup: Equatable {
        var items: [MenuItem]
        var selected: Int?
        /// A symbol before the value (a data part's own symbol, in its color).
        var symbol: String?
        var symbolColor: RGBA?
        /// Each item drawn in its own face (the font menus).
        var fonts = false
        /// The width the popup takes (nil: the row's).
        var width: CGFloat?
    }

    struct MenuItem: Equatable {
        var title: String
        /// Beside the title, quieter (a live value).
        var detail: String = ""
        var symbol: String?
        var enabled = true
        /// A font face to draw the title in.
        var face: String?
        /// A heading line (not chosen).
        var isHeading = false
    }

    struct Segmented: Equatable {
        var items: [String]
        var selected: Int
        var enabled = true
        var width: CGFloat?
        /// SF Symbols in place of the words (the words become their accessibility labels).
        var symbols: [String]? = nil
    }

    /// A color swatch: a part's color, Text, Card (round, and square for the card), or More….
    struct Swatch: Equatable {
        enum Kind: Equatable { case color, text, card, more }
        var id: String
        var kind: Kind
        var color: RGBA?
        /// Text and Card before they are changed: drawn half light, half dark.
        var follows = false
        var label: String
        /// The popover is open on it (or the pointer is on it).
        var active = false
        var tooltip: String?
    }

    struct Swatches: Equatable {
        var parts: [Swatch]
        /// Text, Card and More….
        var pair: [Swatch]
        /// "follow the look", beside the pair while both follow it.
        var followNote: String?
        /// What the pointed-at swatch paints ("The memory ring · 1 part").
        var caption: String?
    }

    struct Thumbnails: Equatable {
        struct Tile: Equatable {
            var title: String
            var image: NSImage?
            var selected: Bool

            static func == (a: Tile, b: Tile) -> Bool {
                a.title == b.title && a.selected == b.selected && a.image === b.image
            }
        }

        var tiles: [Tile]
    }

    struct Link: Equatable {
        var id: String
        var title: String
        var detail: String = ""
        var symbol: String?
        var enabled = true
    }

    struct Note: Equatable {
        var text: String
        var link: String?
        var symbol: String = "scope"
    }

    /// The named confirmation under the control that made a change: "Memory ring is now Mint · Undo".
    struct Confirmation: Equatable {
        var text: String
        var undo: String
        var suggestion: String?
        var suggestionAction: String?
    }

    // MARK: Counting

    /// The controls on the page, as the design counts them: each thing that changes a value is one (a popup, a
    /// segmented control, a switch, a number, each part's swatch, a row of thumbnails); the Text · Card pair, More…,
    /// links, notes, confirmations and A− / A+ are not.
    var controlCount: Int {
        sections.reduce(0) { $0 + $1.items.reduce(0) { $0 + Self.controls(in: $1.kind) } }
    }

    static func controls(in kind: Kind) -> Int {
        switch kind {
        case .row(let row): return controls(in: row.control)
        case .swatches(let s): return s.parts.count
        case .thumbnails, .token, .examples: return 1
        case .dense(let d): return controls(in: d.control)
        case .link, .note, .confirmation, .box: return 0
        }
    }

    /// A pair of controls (width and height) counts as two.
    static func controls(in control: Control) -> Int {
        if case .pair(let items) = control { return items.reduce(0) { $0 + controls(in: $1) } }
        return 1
    }

    /// The design's limit: twelve controls, plus the Text · Card pair.
    static let controlLimit = 12

    func section(_ id: String) -> Section? { sections.first { $0.id == id } }

    func item(_ id: String) -> Item? {
        for s in sections { if let i = s.items.first(where: { $0.id == id }) { return i } }
        return nil
    }
}
