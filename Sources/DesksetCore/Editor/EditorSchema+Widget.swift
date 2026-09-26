import Foundation

/// The widget's own settings (`[Rainmeter]`) and its details (`[Metadata]`), as the inspector's widget page shows them
/// when nothing is selected (docs/editor-friendly.md §8.1). Kept apart from the layer and data groups in
/// EditorSchema.swift so the widget page and the selection pages can change independently.
///
/// Labels use the editor's words (§3.2: "Update speed", "Behind everything", "When someone else installs it"); the
/// widget page builds its cards from them with outcome presets (`WidgetPresets`), and every key listed here counts as
/// shown there (it never lands in "Lines Deskset Can't Show as Controls").
extension EditorSchema {
    // MARK: - Choice lists

    static let backgroundMode: [Choice] = [Choice("0", "A picture"), Choice("1", "Nothing"), Choice("2", "A color"),
                                           Choice("3", "A picture, stretched"), Choice("4", "A picture, tiled")]
    static let alwaysOnTop: [Choice] = [Choice("-2", "On desktop"), Choice("-1", "Behind windows"), Choice("0", "Normal"),
                                        Choice("1", "In front of windows"), Choice("2", "Always in front")]
    static let onHover: [Choice] = [Choice("0", "Do nothing"), Choice("1", "Hide"), Choice("2", "Fade in"),
                                    Choice("3", "Fade out")]

    // MARK: - Widget

    public static let skinGroups: [Group] = [
        Group(title: "Update speed", properties: [
            Property("Update", "How often", num(-1, nil, step: 100, unit: "ms"), default: "1000",
                     help: "How often the widget updates; -1: only when it opens", level: .essential),
        ]),
        Group(title: "Size and spacing", properties: [
            Property("SkinWidth", "Width", num(0, nil, step: 1, unit: "px"), placeholder: "fits its content", level: .essential),
            Property("SkinHeight", "Height", num(0, nil, step: 1, unit: "px"), placeholder: "fits its content",
                     level: .essential),
            // The engine's judgment (Skin.readSettings): without BackgroundMode a widget with a background picture
            // shows the picture, so the picture row stays visible and "A picture" is the value in effect.
            Property("BackgroundMode", "Behind everything", pick(backgroundMode), default: "1",
                     defaultWhen: [ConditionalDefault("0", when: [.isSet("Background")])],
                     help: "Without this option a widget with a background picture shows the picture", level: .essential),
            Property("SolidColor", "Color", .color, default: "128,128,128,255",
                     visibleWhen: [.equals("BackgroundMode", "2")]),
            Property("SolidColor2", "Fades to", .color, placeholder: "none", visibleWhen: [.equals("BackgroundMode", "2")]),
            Property("GradientAngle", "Fade direction", .angle(unit: .degrees, orientation: true), default: "0",
                     visibleWhen: [.equals("BackgroundMode", "2"), .isSet("SolidColor2")]),
            Property("Background", "Picture", .image, visibleWhen: [.equals("BackgroundMode", "0", "3", "4")]),
            Property("BackgroundMargins", "Edges that don't stretch", .insets, visibleWhen: [.equals("BackgroundMode", "3")]),
        ]),
        Group(title: "Timing", properties: [
            Property("DefaultUpdateDivider", "Redraw layers", num(-1, nil, step: 1, unit: "updates"), default: "1",
                     help: "Layers redraw on every update, every 2nd…; -1: only once"),
            Property("TransitionUpdate", "Transition speed", num(16, 86_400_000, step: 10, unit: "ms"), default: "100",
                     help: "How smooth transitions are"),
        ]),
        Group(title: "Size", properties: [
            Property("DynamicWindowSize", "Resize", flag("Resize whenever content changes"), default: "0",
                     help: "Only needed when layers change size while running"),
            Property("AccurateText", "Text boxes", flag("Tight text boxes"), default: "0",
                     help: "Text boxes hug the letters. Recommended.", level: .quiet),
        ]),
        Group(title: "Dragging", properties: [
            Property("DragMargins", "Edges that don't drag the widget", .insets, default: "0,0,0,0"),
        ]),
        Group(title: "Right-click menu", properties: [
            Property("ContextTitle", "Menu item", .text, help: "An extra item in the widget's right-click menu"),
            Property("ContextAction", "When chosen", .action, visibleWhen: [.isSet("ContextTitle")]),
        ]),
        Group(title: "When the widget…", properties: [
            Property("OnRefreshAction", "Opens", .action),
            Property("OnUpdateAction", "Updates", .action),
            Property("OnCloseAction", "Closes", .action),
            Property("OnFocusAction", "Gets focus", .action),
            Property("OnUnfocusAction", "Loses focus", .action),
            Property("OnWakeAction", "Wakes from sleep", .action),
        ]),
        // The page always shows the first four rows (stacking, dragging, clicks, opacity) and every other one once the
        // widget sets it, so each key here is either a control or unset (never counted without showing).
        Group(title: "When someone else installs it", properties: [
            Property("DefaultAlwaysOnTop", "Stacking", pick(alwaysOnTop), default: "-2"),
            Property("DefaultDraggable", "Dragging", flag("Can be dragged"), default: "1"),
            Property("DefaultSnapEdges", "Snapping", flag("Snap to screen edges and other widgets"), default: "1"),
            Property("DefaultClickThrough", "Clicks", flag("Let clicks pass through"), default: "0"),
            Property("DefaultKeepOnScreen", "Keep on screen", flag("Keep on screen"), default: "1"),
            Property("DefaultSavePosition", "Position", flag("Remember the position"), default: "1"),
            Property("DefaultStartHidden", "Start hidden", flag("Start hidden"), default: "0"),
            Property("DefaultAlphaValue", "Opacity", .percent255, default: "255"),
            Property("DefaultOnHover", "When the pointer is over it", pick(onHover), default: "0"),
            Property("DefaultFadeDuration", "Fade time", num(0, 10_000, step: 50, unit: "ms"), default: "250"),
        ]),
        Group(title: "Group names", properties: [
            Property("Group", "Group names", .text,
                     help: "e.g. Clocks — used by actions that change several widgets at once"),
        ]),
    ]

    public static let aboutGroup = Group(title: "About This Widget", properties: [
        Property("Name", "Name", .text, level: .essential),
        Property("Author", "Author", .text, level: .essential),
        Property("Version", "Version", .text, level: .essential),
        Property("Information", "Description", .text, level: .essential),
        Property("License", "License", .text, level: .essential),
    ], summary: "Shown in Manage Widgets and when someone installs it.")
}
