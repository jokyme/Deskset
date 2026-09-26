# Deskset Skin Studio: a friendlier sidebar, inspector and canvas (v4, "Keynote-calm")

> Status: buildable spec. It replaces §2 (sidebar) and §3 (inspector) of `docs/editor-design.md`, and adds the agreed canvas-overflow behaviour. Everything not mentioned here stays as described in `editor-design.md`: the Design | Split | Code modes, the code editor, Settings and routing, and the Shape editor internals.
> Clean room: every behaviour below comes from Deskset's own engine and the public Rainmeter manual. No Rainmeter source was read.

---

## 0. Decision: which design wins, and what it borrows

Three concepts were scored from three perspectives: a newcomer, a Rainmeter veteran, and a macOS design lead.

| Concept | Newcomer | Veteran | Design lead | Total |
|---|---|---|---|---|
| **mac-native** ("Keynote-calm") | 7 | 8 | 8 | **23** ← base |
| contextual ("Click it, change it") | 8 | 7 | 7 | 22 |
| guided ("Simple by default") | 7 | 8 | 6 | 21 |

**We keep mac-native's shape:**
- one scrolling inspector, with no tabs and no global mode;
- an identity strip at the top;
- calm cards, each holding 3–5 settings and ending in one labelled "More … Options" disclosure;
- NSMenu everywhere, so snapshots stay safe;
- a Live Data outline that follows `Parent=`.

**We add from contextual:**
- colours named by what they do, with swatches drawn on the widget's own panel colour;
- update-speed choices that describe their effect;
- a live "On Your Desktop" card;
- visible Undo/Redo in the toolbar and on toasts;
- starter buttons on an empty widget, and new items placed in free space;
- "Shows ▾ → New ▸" that creates and assigns data in one step;
- "↺ Match the Others";
- the floating selection toolbar, in a later phase and kept thin.

**We add from guided:**
- a breadcrumb, and Esc to go up a level;
- the rule that an edit writes to the narrowest place covering exactly what is selected, and the toast then offers to widen it;
- "never hide what's in use";
- overrides written after `@Include`;
- linked-value menus ("Nudge (Keeps the Calculation)" / "Use a Fixed Number Here");
- "X (right edge)";
- status banners;
- all text essentials visible;
- COLORS first on the widget page.

**New, from the reviews:**
- a reorder guard, so relative `r`/`R` chains don't jump;
- the expert switch also opens every "More" section.

### Conflicts and how they were resolved

| Conflict | Decision | Why |
|---|---|---|
| Inspector tabs (contextual) vs one column (mac-native) | **One column.** | People find things by reading down one list. Tabs make users hunt, as both the newcomer and the design lead found. |
| Global Simple/Advanced (guided) vs per-card More (mac-native) | **Per-card "More {Kind} Options"** that says what it contains and "· N in use". **One expert switch**, "Show Rainmeter Details", adds names and opens every More. | A mode is a cliff: one flip brings back the engineer's view. Experts still reach everything with one toggle. |
| Ask for scope before editing (contextual) vs toast afterwards (guided, mac-native) | **Nothing is asked in advance.** A card badge shows who shares the value ("Look shared with 16 bars"). The edit changes exactly the selection. The toast then offers "Apply to All 16 Bars". The only up-front choice is for colours in a file shared with *other widgets*: "Apply to: This Widget \| All 9 Widgets", defaulting to This Widget. | The newcomer found the pre-edit segment confusing. The veteran wanted to see the reach before editing, and the badge does that without asking a question. |
| Sample data on automatically (guided) vs opt-in (the others) | **Opt-in, phase 2.** Phase 1 explains why the widget is still: "No sound is playing, so the bars are still." | An author must be able to tell silence from a broken measure. The banner removes the "is it broken?" doubt at low cost. |
| Colour rows named by variable vs by role | **By role**: "Bar color · 18 bars". The variable name appears in the tooltip and in Rainmeter Details. | "Track" and "Subtle" mean nothing to a designer. |
| Split/checkerboard swatch vs swatch on the panel colour | **Swatch drawn on the widget's panel colour**, plus a "11%" note when opacity is below 100%. | It shows the colour as it really looks. The checkerboard looked technical. |
| Colours card second (mac-native) vs first | **COLORS AND FONTS first.** | Changing colours is the most common first task. |
| Shadow, italic and effect hidden (mac-native) vs visible (guided) | **Visible.** An Italic button sits on the Font row, and Effect is a row of its own. | These are among a designer's most common text changes. |
| Single-layer alignment as "Align in Widget ▾" vs buttons | **Six worded buttons in two rows.** | One click fewer for a frequent action. |
| Floating toolbar now vs later | **Phase 2**, limited to 4–5 controls. It is a shortcut to the inspector's own controls. | It is the largest item. The inspector has to be right first. |
| Canvas backdrop moved to the View menu vs kept in the toolbar | **Stays in the toolbar, relabelled "Backdrop"**, with a View menu copy. | First-time users do look at the toolbar. The new label no longer clashes with the widget's own background. |
| Font size in px (guided) vs pt | **pt for font size, px for position and size.** | This matches Keynote and Pages. |
| Tab name "Data" vs "Live Data" | **Live Data.** | "Data" is vague. |
| Layer filter chips vs search only | **Search only.** It matches names, text, kinds and section names. | 12 rows don't need chips. |
| A bar named after its data ("Left channel level") | **"{short name} bar"** ("Left channel bar") | Otherwise the Live Data row "Left channel level · Used by Left channel level" reads as circular. |

---

## 1. Goals

The side panels should not read like an engineer's tool: people find what they want at a glance, edit it
directly, and a first-time user understands the editor without reading any documentation.

Also: content dragged outside the widget must not silently vanish.
- Draw it as a Keynote-style ghost.
- Grow the widget live to the right and bottom while dragging.
- When something goes past the left or top edge, show a hint and a one-step "Fit Widget to Content".

**Measurable targets (checked by the Friendly walkthrough test, §14.6):**

| # | Target | How we know |
|---|---|---|
| G1 | **Find at a glance.** Every row in Layers and Live Data can be identified without clicking it. | The Visualizer's 26 layer rows become 12 recognisable rows, and 24 data rows become 9. No row title is a section name. |
| G2 | **Edit intuitively.** The seven most common edits are one click away from selecting the thing: words, font, size, colour, what it shows, hide, position. | Each is visible in the first card of the inspector or on the canvas, with no disclosure to open. |
| G3 | **No docs needed.** Nothing in the default UI uses engine vocabulary. | A self-test scans every label of every default inspector state for the banned words in §3.3. |
| G4 | **Nothing silently clipped, nothing silently spread.** | The overflow tests (§9.10), and a toast after every edit that states its reach. |

---

## 2. Principles checklist (every package is reviewed against this)

- [ ] **P1 Recognise, don't recall.** Every layer and data row has a picture (or glyph) and a name taken from its content. Section names appear only in tooltips and with Rainmeter Details on.
- [ ] **P2 One column, no modes.** The inspector has no tabs and no Simple/Advanced switch. The only expert switch is View ▸ **Show Rainmeter Details**.
- [ ] **P3 Essentials first.** Each card shows at most 5 settings (Text allows 7). Everything else goes in one **"More {Kind} Options"** row that lists what it contains.
- [ ] **P4 Never hide what's set.** A non-default value inside a More section is counted ("· 1 in use"), and that More section opens by itself. Quiet keys (AntiAlias, DynamicVariables, AccurateText) are never counted.
- [ ] **P5 Outcomes, not units.** Presets say what happens ("Every second — Right for clocks and system stats"). The default UI shows no "ms", no INI keys, no `#Var#` and no "f(x)".
- [ ] **P6 What you selected is what changes.** Widening is one explicit click in the toast, or happens on a card that says up front that it changes everything.
- [ ] **P7 Show the reach.** Every shared value shows a count, and hovering it outlines its users on the canvas. Clicking the count selects them.
- [ ] **P8 Everything undoes, and says so.** Every change is one named undo step, desktop settings included. Every toast has **[Undo]**.
- [ ] **P9 Teach in place.** Captions, placeholders on the canvas, status banners, and at most 3 one-time tips.
- [ ] **P10 Never silently clip.** Overflow is ghosted, the widget grows, or a Fit chip appears.
- [ ] **P11 Fidelity.** Nothing the UI can't show as a control is overwritten. It is shown as a sentence, a raw line, or "Edit in Code".
- [ ] **P12 Calm and snapshot-safe.** Keep the approved style: dot grid, shadowed widget, cards, swatches, zoom pill, toasts. Use NSMenu or in-window overlays only (never NSPopover), and add every new overlay to `snapshot()`.

**Kept exactly as they work today:**
- Add-tab cards and drag-to-canvas.
- Schema-driven controls, the Shape editor and the Code split.
- Multi-select, align and distribute.
- `GeometryEdit.offset`, which keeps the written form of `#BarGap#R`, `0r` and `(…)` values.
- The preview → `commit`/`perform` → one undo step → refresh pipeline.
- The font menu that draws each font in itself.
- Live reload.

---

## 3. Vocabulary and copy rules

### 3.1 Glossary (one word per idea, everywhere)

| Word in UI | Means |
|---|---|
| **Widget** | the whole skin (config). "Rainmeter skin" only in *Import Rainmeter Skin…* and install flows. |
| **Layer** | anything drawn (a meter / section). |
| **Live data** | where numbers and words come from (a measure). |
| **Look** | a shared set of settings (MeterStyle), used in "Look shared with 16 bars". |
| **Shared color / shared size / shared font** | a variable, as used by the widget. |
| **Update speed** | how often it updates. Never "refresh". |

### 3.2 Engine term → UI label

| Engine | UI label |
|---|---|
| skin / config | widget |
| `@Resources` | the widget's shared files (only in tooltips) |
| meter / section | layer |
| String | Text |
| Image (with file) / Image (no file, SolidColor) | Picture / Color block |
| Bar | Bar |
| Line | Line graph |
| Histogram | Bar graph |
| Roundline | Gauge |
| Rotator | Dial |
| Bitmap | Number picture |
| Button | Button |
| Shape | Shape (kinds: Rectangle, Rounded rectangle, Circle, Line, Path) |
| measure / data source | live data |
| plugin | (hidden; the "Extras" menu group) |
| Calc | Formula (value marked "calculated") |
| MeterStyle | look |
| `#Variable#` | shared color / size / font / value |
| formula `( … )` in an option | calculated |
| `X=nR` / `Y=nr` | "n px after {layer}" / "Same top as {layer}" |
| `[Measure]` in X/Y | "moves with {data}" |
| Update | Update speed |
| DefaultUpdateDivider / UpdateDivider | Redraw layers / Redraw |
| TransitionUpdate | Transition speed |
| DynamicWindowSize | Resize whenever content changes |
| AccurateText | Tight text boxes |
| DragMargins | Edges that don't drag the widget |
| Group | Group names |
| ContextTitle / ContextAction | Right-click menu item |
| OnRefreshAction / OnUpdateAction / OnCloseAction / OnFocusAction / OnUnfocusAction / OnWakeAction | When the widget opens / updates / closes / gets focus / loses focus / wakes from sleep |
| Default* keys | When someone else installs it |
| AlwaysOnTop | Stacking |
| Draggable | Lock position (inverted) |
| ClickThrough | Let clicks pass through |
| SnapEdges | Snap to screen edges and other widgets |
| KeepOnScreen | Keep on screen |
| AlphaValue | Opacity |
| FadeDuration | Fade time |
| OnHover | When the pointer is over it |
| SkinWidth / SkinHeight | Size: Fixed Size |
| BackgroundMode / Background / SolidColor (skin) | Behind everything |
| MeasureName | Shows |
| `%1` in Text | the blue data tag |
| Prefix / Postfix | Text before / Text after |
| NumOfDecimals / AutoScale / Scale / Percentual | Number (one menu of rendered examples) |
| StringAlign | Align (horizontal) + Up and down (vertical) |
| StringCase | Capitals |
| StringEffect + FontEffectColor | Effect (None / Shadow / Outline) + colour |
| StringStyle / FontWeight | Italic button / Weight |
| ClipString | If it's too long |
| AntiAlias | Smooth edges |
| InlineSetting / InlinePattern | Styled parts |
| Angle | Rotation |
| SolidColor / SolidColor2 on a meter | Box behind it (colour / fades to) |
| Padding | Space around it |
| BevelType | Raised edge |
| BarColor | Fill |
| SolidColor on a bar | Empty part |
| BarOrientation + Flip | Fills toward |
| BarImage | Picture instead of a color |
| MinValue / MaxValue | Lowest / Highest value |
| InvertMeasure | Flip the value |
| AverageSize | Smooth over the last N readings |
| IfCondition / IfAbove… | When the value… |
| Substitute | Replace text |
| Disabled / Paused | Turned off / Paused |
| Container | Show only inside |
| TransformationMatrix | Custom transform |
| Hidden | Hide |
| LeftMouseUpAction | When clicked |
| MouseOverAction / MouseLeaveAction | When pointed at / When the pointer leaves |
| ToolTipText | Tooltip |
| bang / action | action (in sentences: "Opens “Activity Monitor”") |
| Refresh (reload) | Reload Widget |
| skin.issues | Doesn't Work on a Mac |

### 3.3 Copy rules

- **Case.**
  - Title Case: buttons, menu commands, segment labels and disclosure titles.
  - Sentence case: row labels, captions, pop-up choices, checkboxes, tips and toasts.
  - Card titles: the existing small caps.
- **Units.** px for position and size; pt for font size only. The nudge hint changes from "10 pt" to **"10 px"**.
- **Quotes.** A text layer's name is its text in curly quotes, trimmed to 28 characters plus "…".
- **Banned in the default UI** (self-test G3):
  - words: `skin`, `meter`, `measure`, `section`, `variable`, `MeterStyle`, `ms`, `INI`, `.inc`, `.ini`, `f(x)`, `Refresh`;
  - patterns: `#…#`, any `R,G,B,A` text.
  - Allowed exceptions: *Import Rainmeter Skin…*, "Show Rainmeter Details", the Code pane, and anything shown while Rainmeter Details is on.
- **Toasts** never name a file or a section.

---

## 4. Window chrome

```
[◧]  Audio Visualizer      [↶] [↷]    [+ Add]    [ Design | Split | Code ]    [Backdrop ▾] [Live Reload] [Open in ▾] [⋯] [◨]
```

- **Undo/Redo (new).**
  - ↶ / ↷ are toolbar buttons. Their tooltips name the step: "Undo Change Bar Color", "Redo Hide “Audio”".
  - They are disabled when there is nothing to undo or redo.
- **+ Library becomes "+ Add"** (⇧⌘L, unchanged). It opens the Add tab and focuses its search field.
- **Backdrop.** The old toolbar label "Background" becomes **"Backdrop"**.
  - Tooltip: "The color behind your widget in the editor. It isn't part of the widget."
  - It is mirrored in View ▸ **Canvas Backdrop ▸** (existing cases).
- **View menu additions:**
  - **Show Rainmeter Details** (toggle). This is the existing `showIniNames` preference under a new label.
  - **Show Content Outside the Widget** (toggle, on by default).
  - "Refresh Skin" (⌘R) is renamed **Reload Widget** (⌘R).
- **Help menu:** **Show Tips Again**.
- **Settings ▸ Editor:** the checkbox "Show INI option names" becomes **"Show Rainmeter details (option names, section names and every setting)"**.

---

## 5. Left sidebar: `[ Add | Layers | Live Data ]`

### 5.1 Add tab (was Library; cards unchanged)

```
[ Search things to add                    ]
Drag onto your widget, or click to add it below what's there.      ← 11 pt secondary; always shown
[All] [Text] [Live Data] [Graphs] [Gauges] [Shapes] [Pictures]      ← chip "Images" renamed "Pictures", "Data" → "Live Data"
[card grid: live thumbnail · name · one-line description · data badge]   ← unchanged
```

- **Tip T3** appears the first time this tab opens (§12).
- **Clicking a card** places the new layer in free space:
  - Position: 8 px below the lowest visible layer, left-aligned with the leftmost content edge.
  - It never lands on top of another layer, and it never lands 10 px under the selection.
  - The widget grows to fit (§9.10). Toast: **"Added Clock · Widget grew to 217 × 240 · [Stretch Background] [Undo]"**. "Stretch Background" appears only when a detected Background no longer covers the widget.
- **Dropping** a card works as today (ghost and snap guides). It is now allowed past the right or bottom edge; the widget grows.
- **Copy fixes:**
  - "A picture from the skin folder" → **"A picture from the widget's folder"**.
  - No results → **"Nothing matches “xyz”."**

### 5.2 Layers tab

**Visualizer, as a user will see it.** Rows are 40 pt. The first line of each row is the title and the second line is the subtitle.

```
[ Find a layer                              ]
┌─────────────────────────────────────────────┐
│ [widget]  Audio Visualizer                  │   always the first row; selecting it = nothing selected (widget page)
│           Whole widget · 217 × 196          │
└─────────────────────────────────────────────┘
FRONT                                              ← 10 pt tertiary caption
[▮]   Peak marker                                  Color block · moves with peak level
[━]   Right channel bar                            Bar · right channel level
[R]   “R”                                          Text
[━]   Left channel bar                             Bar · left channel level
[L]   “L”                                          Text
[Hz]  “13268 Hz”                                   Text · highest band frequency
[Hz]  “48 Hz”                                      Text · lowest band frequency
▸[▮▮▮] 16 bars                                     Bar · sound bands 1–16
[Aa]  “MacBook Pro扬声器”                           Text · output device name
[Aa]  “Audio”                                      Text
BACK
[■]   Background                            🔒     Rounded rectangle · whole widget
```

This takes the list from 26 rows to 12 (11 layer rows plus the widget row). The widget row is the list's first row and scrolls with it (the canvas's empty area selects the widget too).

**Row anatomy**
- **Thumbnail:** 36×26 pt with 5 pt corners. It shows the layer's real pixels, drawn on the widget's own panel colour (the detected Background fill, else the backdrop).
- **Glyph fallback:** layers narrower or shorter than 6 pt (Peak marker 2×27, single bars) show a kind glyph drawn in the layer's own colour instead.
- **Title:** 13 pt, one line, tail-truncated. **Subtitle:** 11 pt secondary.
- **Trailing status icons.**
  - Always visible: eye-slash when hidden, lock when locked, yellow ⚠ when part of the layer is cut off on the desktop.
  - Shown on hover: eye and lock toggles.
  - Tooltips:
    - eye: "Hide this layer" / "Show this layer";
    - lock: "Lock it so it can't be moved by accident" / "Unlock";
    - ⚠: "Part of this layer is outside the widget and won't show on the desktop."
- **Hidden rows** are drawn at 45% opacity.
- **Selection** is a rounded accent tint at 18% opacity, drawn by a custom `NSTableRowView` (`selectionHighlightStyle = .none`). Text keeps `labelColor`.
  - This fixes today's solid black selected row. The source-list emphasis renders black off-screen and hides the name.
  - Hover draws the same shape at 7%.
- **Row tooltip** gives the section for experts: **"MeterTitle — double-click to type"**. Non-text rows: "MeterBand5".
- **Rainmeter Details on:** the subtitle gains " · MeterTitle".
- **Accessibility label:** "“Audio”, Text".

**Groups (repeated layers)**
- **What counts as a group:** 3 or more consecutive layers in file order, with the same meter type, the same look list, no container, and names that differ only by a trailing number.
- **Group row:**
  - Title "{N} {kind plural}" (**"16 bars"**); subtitle "{kind} · {data} {first}–{last}" (**"Bar · sound bands 1–16"**).
  - Thumbnail: a crop of the members' union.
- **Expanding it (▸)** shows its members indented 12 pt, in left-to-right file order:

  ```
  Bar 1     Sound band 1 of 16 (lowest)
  …
  Bar 16    Sound band 16 of 16 (highest)
  ```
- **Clicking the group row** selects all 16 bars.
- **The group row's eye and lock** act on all 16 at once, as one undo step ("Hide 16 Bars").
- **Dragging the group row** moves the whole run as a block, in one `perform`. You can't drop other rows between members, and members can't be reordered.
- **Open/closed state** is remembered per widget (existing `inspectorState`).
- **Canvas selection of a member** expands the group and highlights the member row.

**Background**
- **What counts as Background:** a Shape or Picture that is drawn first and covers at least 90% of the widget. It is titled "Background".
- It is **locked in the editor automatically**. This lock is editor state, never written to the file; see §9.6.
- Unlocking it is remembered per widget.

**Hover links the list and the canvas (both ways)**
- Hovering a row outlines that layer on the canvas and lays a 30% veil over the rest of the widget. A group row outlines all 16 bars.
- Hovering a layer on the canvas highlights its row with the hover tint and scrolls it into view. The scroll only happens when the pointer isn't over the sidebar.

**Search** ("Find a layer")
- It matches titles, text, kind words ("text", "bar", "picture") and section names.
- While a search is active, dragging is off, and the caption reads **"Clear the search to change the order."**

**Row context menu**
```
Hide                         (Show when hidden)
Lock                         (Unlock)
—
Duplicate                    ⌘D
Delete                       ⌫
Arrange ▸   Bring to Front ⇧⌘]  ·  Bring Forward ⌘]  ·  Send Backward ⌘[  ·  Send to Back ⇧⌘[
—
Select All 16 Bars           (group members, or "Select All 5 Small Texts" for layers sharing a look)
Do Something When Clicked…
—
Show in Code
```
Group rows add **"Show as Separate Rows"**. That choice is remembered per widget.

**Reorder guard.** Some drops would change what another layer is placed after (`r`/`R` anchors or `[Meter:X]` references). For those:
- The editor keeps every layer where it is. It rewrites only the affected X/Y values to fixed numbers, in the same undo step.
- Toast: **"Moved “48 Hz” to the front. “13268 Hz” now uses a fixed position, so nothing moved. · [Undo]"**.
- Moving a whole group keeps its internal chain.

**Empty state:** **"Nothing here yet. Drag something from Add onto your widget."** [Open Add]

### 5.3 Live Data tab

```
[+ Add Live Data ▾]      [ Find live data          ]
Where the numbers and words in your widget come from.          ← always shown, card-note style

┌ No sound is playing, so the bars are still. Play something to see them move. ┐   ← status banner, only when relevant

▾ [〰] Sound from your Mac                               Silent
       What your Mac plays
   ▸ [〰] 16 sound bands                                 ▁▁▁▁▁▁   (mini strip)
          Used by 16 bars
     [〰] Left channel level                             0%
          Used by Left channel bar
     [〰] Right channel level                            0%
          Used by Right channel bar
     [〰] Peak level                                     0%
          Used by Peak marker position
     [〰] Output device name                             MacBook Pro扬声器
          Used by “MacBook Pro扬声器”
     [〰] Lowest band frequency                          48 Hz
          Used by “48 Hz”
     [〰] Highest band frequency                         13.3 kHz
          Used by “13268 Hz”
  [ƒ] Peak marker position                               36
      Calculated from peak level · used by Peak marker
```

- **Hierarchy.** Children are grouped under their `Parent=`. Repeated data (MeasureBand0…15) folds into one row. Expanded members are titled "Band 1 … Band 16" (1-based).
- **Values are formatted:**
  - 0–1 ranges as %; bytes as GB/MB; network as MB/s; frequencies as Hz/kHz;
  - text in full, tail-truncated with a tooltip. This fixes text longer than 12 characters showing as "0".
- **"Used by"** names are links. Hovering one outlines the layer; clicking selects it.
- **Data nothing uses** is drawn at 55% opacity, with the subtitle **"Not used by any layer"** and a hover button **[Delete]**.
- **Status banners** (one at a time):
  - **"No sound is playing, so the bars are still. Play something to see them move."**
  - **"Deskset can't hear your Mac's sound yet."** [Allow…] (existing audio-permission request).
  - **"This live data doesn't work on a Mac, so it reads 0."** (Windows-only types). As built, it names the item when there is one (**"Windows registry doesn't work on a Mac, so it reads 0."**), else counts them (**"3 live data items don't work on a Mac, so they read 0."**); the rows themselves carry a ⚠ and the line "Doesn't work on a Mac".
- **Row menu:** Show in a New Text Layer · Duplicate · Delete · Show in Code.
- **Empty state:** **"Live data brings numbers into your widget — CPU, memory, network speed, battery, time and more."** [+ Add Live Data]
  - Second line: **"Most things in Add already come with their live data."**

**"+ Add Live Data" menu.** Each item is two lines: the name, then a grey one-line description. The same catalogue appears under "New ▸" in every Shows menu.

| Section | Item | Description |
|---|---|---|
| **On This Mac** | CPU usage | How busy the processor is (0–100%) |
| | Memory used | How much memory apps are using |
| | ~~Swap used~~ | *Dropped (design review): SwapMemory counts the memory plus the swap, so this item would have promised the swap and shown more. SwapMemory is under Extras as "Memory and swap used".* |
| | Network speed ▸ Download · Upload · Both | Download or upload speed |
| | Disk space | Free or used space on a disk |
| | Battery | Charge level and status |
| | Time and date | The current time or date |
| | Time since startup | How long your Mac has been on |
| | Sound | Loudness and spectrum of what's playing |
| | Now playing | The song in Music or Spotify |
| | Wi-Fi signal | How strong the Wi-Fi is |
| | Mac info | Computer name, macOS version, user… |
| | Running app | Whether an app is open |
| **Calculate** | Formula | Math on other live data |
| | Counting number | A number that counts up |
| | Random number | A new random number each update |
| **From the Web** | Text from a web page | Reads a value from a page |
| **Extras (limited on a Mac) ▸** | everything else | plain names |

"Memory in use (Windows-style)" is hidden. Windows-only types appear only with Rainmeter Details on, marked "Doesn't work on a Mac".

---

## 6. Naming rules (Core `LayerNaming`)

The same name is used everywhere: rows, canvas tags, identity strip, breadcrumbs, toasts and undo names.

### 6.1 Layers

| Layer | Title | Subtitle | Sentence (identity strip) |
|---|---|---|---|
| Text, literal | the text in curly quotes, ≤28 characters | "Text" | "Text that says “Audio”." |
| Text with data | the rendered text ("“48 Hz”"); if empty, "{data name} (empty)" | "Text · {data name}" | "Text showing the lowest band frequency, written as “48 Hz”." |
| Bar / Line graph / Bar graph / Gauge / Dial | "{data short} {kind noun}": "Left channel bar", "CPU graph", "CPU gauge". With no data, the kind ("Bar"). | "{Kind} · {data name}", or "{Kind} · not showing anything yet" | "Bar showing the left channel level, filling to the right." |
| Picture with a file | the file name, humanised ("clock face") | "Picture" | "Picture “clock face.png”, 120 × 120." |
| Picture from live data (`MeasureName`, or `%1` in ImageName) | the data's name when it names a picture ("Album cover"), else "{data short} picture" | "Picture · {data name}" | "Picture showing the album cover, 72 × 72." |
| Colour block (Image, no file) | "{data short} marker" when X/Y follows data, else "Color block" | "Color block · moves with {data}" | "A 2 × 27 white block that moves with the peak level." |
| Shape | "Background" (see §5.2); when a formula uses data, "{data short} bar" for a rectangle ("Memory bar"), "{data short} progress line" when it is at most 4 px tall, else "{data short} shape"; else the kind ("Rounded rectangle", "3 shapes") | "{kind} · whole widget" / "Shape" | "Rounded rectangle, 217 × 196, behind everything." |
| Gauge / dial with no data that draws anyway (Solid=1, a line, a picture: a clock face, rim, tick) | the kind | "{Kind} · fixed shape" | "Gauge drawn as a fixed shape, 200 × 200." |
| Group | "{N} {kind plural}" | "{Kind} · {data} {first}–{last}" | "16 bars showing sound bands 1–16, low to high." |
| Group member | "{Kind} {n}", 1-based ("Bar 6") | "{data name} of {N}" | "Bar showing sound band 6 of 16, filling upward." |
| Fallback | the humanised section name, "Meter" prefix dropped ("MeterLeftLabel" → "Left label") | kind | "{Kind}." |

- **Text titles** refresh at most once per 0.5 s tick. Rows are never re-sorted by name.
- **Titles several layers share** (not texts, not members of a run) are told apart: each takes its humanised section
  name when that says more than the kind ("Hour hand", "Tick 12", "Previous"), else a number in file order ("CPU graph
  2"). A subtitle that would repeat the title gets the size ("Color block · 40 × 40").
- **Empty text whose data a setting chose** (`MeasureName=MeasureSuffix#ClockHours#` in 24-hour mode) is named after
  the data the setting can choose otherwise: "AM/PM (empty)".
- **Section names** stay the identity for code, errors, pasteboards and `select(section:)`: `Item.title` is unchanged, and `Item.display` is new.

### 6.2 Live data

Every data item has a **name** and a **short** form. The name is built from its type plus its distinguishing settings.

| Type | Name | Short |
|---|---|---|
| CPU (Processor=0 / N) | CPU usage / CPU core N usage | CPU / Core N |
| PhysicalMemory | Memory used (Free=1 → Memory free; Total=1 → Total memory) | Memory |
| Memory (the Windows commit total: memory twice plus swap) | Memory used (Windows-style) (Free / Total likewise) | Memory |
| SwapMemory (memory plus swap, as Windows counts memory plus its page file) | Memory and swap used (Free=1 → Memory and swap free; Total=1 → Total memory and swap) | Memory + swap |
| Calc of SwapMemory − PhysicalMemory (both used, free or total) | Swap used / Swap free / Total swap | Swap |
| NetIn / NetOut / NetTotal | Download speed / Upload speed / Network speed | Download / Upload / Network |
| FreeDiskSpace | Free space on {volume name} (InvertMeasure=1 → Used space on …) | Disk |
| Time | what its format shows: Hours and minutes (12-hour when %I), Time with seconds, Seconds, Minutes, Hour, AM/PM, Weekday, Week number, Day of the month, Month number, Month name, Year, Month and year, Date, Date and time — never a rendered example (it froze a moment that contradicted the live value) | Time, Seconds, Weekday, Week, Date… |
| Uptime | Time since startup | Uptime |
| Battery (PowerPlugin) | Battery level | Battery |
| AudioLevel parent | Sound from your Mac (Port=Input → Sound from the microphone) | Sound |
| AudioLevel Band, BandIdx=k | Sound band k+1 | Band k+1 |
| AudioLevel RMS L/R, Avg/Sum | Left / Right channel level; both channels: Sound level | Left channel / Right channel / Level |
| AudioLevel Peak | Peak level | Peak |
| AudioLevel DeviceName | Output device name | Device |
| AudioLevel BandFreq (first / last / k) | Lowest band frequency / Highest band frequency / Band k+1 frequency | Frequency |
| Calc used only as one layer's X/Y | "{layer} position" (Peak marker position) | — |
| Calc that reads its own value | Counting number (a block it places: "Moving block", "Color block · moves on its own") | Counter |
| Calc that is only another item (`Formula=MeasureWeekText`) | that item's name | its short |
| Calc `A / B * 100` | "{A} as %" | A's short |
| other Calc | "Calculated from {the data its first reference comes from, through other formulas}"; "Calculated number" when that chain is too long, never "calculated from calculated from…" | Formula |
| WebParser | Text from {host, or the file name for a file on this Mac}; a child with StringIndex N: Value N from {host} | Web |
| NowPlaying | Song title / artist / year / genre / rating / lyrics / file, Album, Album cover, Track number, Song length / position / progress, Player volume, Play state, Whether the player is open, Shuffle, Repeat | Song, Cover… |
| WiFiStatus | Wi-Fi network name / signal / send speed / receive speed / encryption / security / standard, Nearby Wi-Fi networks | Wi-Fi |
| String | Fixed text | Text |
| Fallback | today's `EditorStyle.describe`, e.g. "Processor usage" | same |

- Band numbers are always shown 1-based.
- Repeated data folds into "{N} {plural}" ("16 sound bands"). Members that would all have one name are numbered
  ("Weekday 3", "Calculated number 8") and the run is "7 weekdays" / "42 calculated numbers" — never
  "{N} × {section name}".
- A MeasureName built from a variable (`MeasureTime#ClockHours#`) uses every data item the variable could choose:
  none of them is "Not used by any layer". Data a file other widgets read defines is never offered for deleting.

---

## 7. Inspector anatomy (shared by every state)

### 7.1 Identity strip (replaces `header(...)`)

```
‹ Audio Visualizer › 16 bars                               ← breadcrumb: ancestors only, 11 pt, each part a link
[picture 48×48]  Bar 6                                     ← 17 pt semibold
                 Bar showing sound band 6 of 16, filling upward.   ← 12 pt secondary, wraps
[✎ Edit Text] [👁 Hide] [🔒 Lock] [⋯]                     ← small bordered buttons, icon + word
⚠ Part of this layer is past the left edge and won't show on the desktop.  [Fit Widget to Content]   ← only when cut off
```

- **Breadcrumb.**
  - A top-level layer shows "‹ Audio Visualizer". A group member shows "‹ Audio Visualizer › 16 bars".
  - Clicking a part selects it. Esc does the same as clicking the last part.
- **Buttons.**
  - **[✎ Edit Text]** appears for Text layers only. Literal text starts in-place editing on the canvas; data text focuses the Text field.
  - **[Hide] / [Show]**, **[Lock] / [Unlock]**. A group shows **[Hide All] / [Lock All]**.
  - **⋯ menu:** Duplicate · Delete · Arrange ▸ · Select All N … · Show in Code.
- **Rainmeter Details on:** adds a third line with the existing link, `[MeterBand5] · Visualizer.ini:287 ↗`, and "Looks: StyleBand".

### 7.2 Cards

- Each card has a title (small caps), 3–5 essential rows (Text allows 7) and an optional one-line note (`Group.summary`).
- Cards end with **one** disclosure row:
  - Label: **"More {Kind} Options"**, with a grey list of its contents after it (`Group.moreSummary`), then **"· N in use"** when relevant.
  - Example: `▸ More Text Options   capitals, up and down, long text, text before and after, rotation · 1 in use`.
  - If any contained value is set to a non-default value (quiet keys excepted), the disclosure **opens by itself**. The set rows show a small dot before their label.
  - Open/closed state is remembered per widget and card (`inspectorState.disclosures`).
  - **Rainmeter Details opens every disclosure** and adds the INI key under each label (existing `showIniNames` rendering). It also shows the **"Lines Deskset Can't Show as Controls (N)"** card: editable `key = value` rows, only when there are any.
- **Look badge.** When a card's values come from a look, the card title carries one badge on the right: **"Look shared with 16 bars"**. It replaces every per-row magenta "from StyleX".
  - Hovering the badge outlines those layers. Clicking it selects them.
- **Outcome buttons** replace the grey "+ Data + Background + Interaction + Behavior" links. They sit at the end of the inspector and appear only when their group is empty:
  - **"+ Show Live Data…"** (literal text only). Opens the Shows menu; picking an item turns Text into "{old text} %1".
  - **"+ Add a Box Behind It…"** adds `SolidColor` (the theme panel colour, else 0,0,0,128) and `Padding=4,2,4,2`.
  - **"+ Do Something When Clicked…"** opens the click-action picker (§8.2).

### 7.3 Linked values (replaces the "#" and "f(x)" pills)

A linked number shows its **effective value in the normal number field**, plus a quiet grey **tag** after it. The tag is a pull-down.

| Written value | Field | Tag | Tag menu |
|---|---|---|---|
| `#Left#` | 14 | **Left** | Change ‘Left’ for All 10 Layers… · Use a Fixed Number Here · Highlight the 10 Layers |
| `(36 + #BarH# + 4)` | 136 | **calculated** | Use a Fixed Number Here · Show the Calculation… · Highlight What It Depends On |
| `#BarGap#R` | 74 | **3 px after Bar 5** | Use a Fixed Position Here · Select “Bar 5” |
| `0r` | 136 | **Same top as “48 Hz”** | Use a Fixed Position Here · Select “48 Hz” |
| `[MeasurePeakX]` | 36 | **moves with peak level** | Use a Fixed Position Here · Show the Live Data |

- **Typing, arrow keys and dragging always go through `GeometryEdit.offset`,** so the link is kept.
  - `#Left#` + 6 is written as `(#Left# + 6)`, and the tag reads **"Left + 6"**.
  - Nudging a calculated value keeps the calculation. Tooltip: **"Nudging keeps the calculation."**
  - The raw text appears in the tag's tooltip (`(36 + #BarH# + 4)`) and in Rainmeter Details.
- **"Change ‘Left’ for All 10 Layers…"** turns the field into an editor for the shared value itself. The field gets an accent ring and the caption **"Changing Left for 10 layers."** Return writes the variable, and Esc goes back.
- **"Show the Calculation…"** reveals an inline formula field under the row, with the caption **"Math on other values. Numbers and names of shared sizes work here."**

### 7.4 Colour control (every colour in the inspector)

`[■ Bar color ▾]  11%`
- **Swatch:** a 22×16 rounded swatch drawn over the widget's panel colour. The opacity is written after it when below 100%.
- **Name:** the role name when the value is linked (§8.1.1), else "Custom".
- **Tooltip:** "#78C8FF · 100% opacity". With Rainmeter Details: "Accent · 120,200,255,255".
- **Click opens an NSMenu** (snapshot-safe):

```
Bar color · 18 bars                         (disabled header)
—
THEME COLORS
  ■ Bar color
  ■ Empty part of bars
  ■ Small text
  ■ Title text
USED IN THIS WIDGET
  ■ Background panel
  ■ Peak marker
—
Custom Color…                               → NSColorPanel, live preview, one undo step on close
Change ‘Bar color’ Everywhere (18 bars)…    (only when linked; edits the shared color)
Copy Color Code                             (#78C8FF)
```

- Picking a theme colour writes the reference (`#Accent#`). Picking a colour from "Used in this widget" writes the literal.

### 7.5 Where an edit is written ("what you selected is what changes")

For a selection **S** and a property, the edit is written to the narrowest target that covers exactly S. `ScopeResolver` in `EditorPropertyWriting.swift` makes the choice:

1. **The shared value (variable).** Used when the current value is exactly `#Var#`, S equals every layer in this widget that uses Var, **and** Var is defined in this widget's own files.
2. **The look.** Used when the value comes from look L, S equals every user of L, and L is defined in this widget's own files.
3. **Otherwise,** each selected layer's own section. This is today's "Override on this layer".

**Explicit exceptions, each announced on its card up front:**
- The widget page's COLORS AND FONTS and SIZE AND SPACING cards always edit the shared value. Their card note says so.
- A group's SPACING card edits the members' shared sizes. It notes other users, for example **"Also moves “48 Hz”."**

**A file other widgets share is never rewritten for this widget alone** (`Skin.localTarget`):
- A layer's, look's or `[Rainmeter]` key a shared include defines gets this widget's own value, written after the block's
  `@Include` lines (read later, it wins). A shared fixed size is undone with this widget's own `SkinWidth=0`.
- A layer only a shared file defines can't change for this widget alone (its own block would move it in the drawing
  order): it stays, and the toast says so. Fit Widget to Content refuses rather than moving the others without it.
- A value written for this widget that still loses (an `@Include` read after it) is put back, with no undo step, and
  the toast says why. "All N Widgets" writes the shared file and removes this widget's own value.

**Afterwards, the toast offers the next wider target:**
- **"Changed Bar 6 only · [Apply to All 16 Bars] [Undo]"**. This writes the look and removes Bar 6's own key, in one step.
- **"Changed “System” only · [Apply to All 6 Widget Titles] [Undo]"** (a look in a shared file).
- **"Changed the 16 bars · [Change ‘Bar color’ Everywhere] [Undo]"**.

**↺ Match the Others.** When a layer has its own value for a key its look also sets, that row shows a small link **"↺ Match the Others"** (tooltip: "Use the look's value again").
- Clicking it removes the key via `IniKeyRemoval`, as one undo step "Match the Others".

**Undo names state the reach:** "Change Fill of Bar 6", "Change Fill of 16 Bars", "Change Bar Color".

---

## 8. Inspector states (exact copy)

Examples use `TestSkins/Audio/Visualizer`, except where System is named (`DefaultSkins/Deskset/System`).

### 8.1 Nothing selected: the widget page

```
[widget thumb]  Audio Visualizer
                A widget with 26 layers that updates 40 times a second.   ← "updates 40 times a second" is a link to UPDATE SPEED
                217 × 196 px                                              [⋯]  Show in Code · Reveal in Finder · Show in Manage Widgets · Reload Widget
┌ Click anything in your widget to change it. Drag new things in from Add.  [×] ┐   ← tip T1, first open only

COLORS AND FONTS
Change one and everything that uses it follows. Point at one to see where.
  [■] Bar color                                 18 bars
  [■] Empty part of bars          11%           18 bars
  [■] Small text                                5 texts
  [■] Title text                                “Audio”
  [■] Background panel            92%           Background
  [■] Peak marker                 78%           1 layer
  Title text   [Helvetica Neue      ▾]  [ 11 ] pt      “Audio”
  Small text   [Helvetica Neue      ▾]  [  8 ] pt      5 texts

UPDATE SPEED
  How often    [Real-time — 40 times a second      ▾]
               Smoothest animation. Uses the most battery.

ON YOUR DESKTOP                                         Applies right away on this Mac.
  Stacking     [ On Desktop | Normal | Always on Top ]
               Sits on the desktop, behind all windows.
               ☐ Lock position
               ☐ Let clicks pass through
  Opacity      [———————————●] 100%
  ▸ More Desktop Options   snapping, keep on screen, fade, when pointed at

SIZE AND SPACING
  Size         [ Fits Its Content | Fixed Size ]    217 × 196 px now
  Behind everything   Nothing — the dark panel is the layer “Background”.  [Select It]
  Bar width    [  9 ] px          16 bars
  Bar gap      [  3 ] px          15 bars
  Bar height   [ 96 ] px          16 bars and “48 Hz”
  Left         [ 14 ] px          left edge of 10 layers
  Width        217 px · calculated                [Edit Calculation…]

▸ Doesn't Work on a Mac (2)                      ← only when skin.issues isn't empty
▸ About This Widget        name, author, version, description
▸ More Widget Options      timing, right-click menu, actions, looks · 1 in use
```

#### 8.1.1 COLORS AND FONTS

- **Which rows:** every distinct colour the widget's layers use, from a variable or written directly, grouped by value and sorted by number of users.
  - The first 6 show; the rest sit behind **"Show 3 More Colors"**.
  - Colours only other widgets use go to More Widget Options ▸ "Colors other widgets use (12)".
  - Internal values (Theme, ThemeNext, menu titles, action strings) appear only with Rainmeter Details.
- **Row title = role**, taken from the options that use the colour:

  | Used as | Role name |
  |---|---|
  | BarColor | "Bar color" |
  | SolidColor of bars | "Empty part of bars" |
  | FontColor through a look | "{Look humanised} text" ("Small text") |
  | FontColor on one layer | "{humanised section} text" ("Title text"), or "{layer title} text" if the section name ends in digits |
  | Fill of the detected Background | "Background panel" |
  | LineColor | "{data short} graph line" |

  - Mixed roles take the most-used role plus " and N more" ("CPU graph line and 2 more"). The subtitle lists them all.
  - The variable name appears only in the tooltip and with Rainmeter Details.
- **Merged same-value variables.**
  - Row caption: **"Changes 3 shared colors"**. Row menu: **"Show Separately"**.
  - System example: *CPU graph line and 2 more — CPU graph line, download graph line, title when pointed at*.
- **Counts** are blue links (select the users). Hovering a row pulses the users' outlines (`canvas.relatedNames`).
  - Counts are marked **"at least 5"** when dynamic names (`[#Color[#Index]]`) can't be resolved.
- **Swatch** click → colour menu (§7.4). Editing writes the variable. For a literal it writes every occurrence in this widget's own files, including inside Shape strings, as one undo step. The row shows the reach before you edit ("1 layer").
- **Fonts:** one row per font source (look / variable / single layer), with the same role naming. Face pop-up plus size in pt. Weight lives on the layer page.
- **Colours from a file shared with other widgets** (System):

```
ⓘ These colors come from the Deskset theme, shared by 9 widgets.
Apply to   [ This Widget | All 9 Widgets ]
           Only System changes. Also used when you switch to the Light look.      ← This Widget
           Changes every Deskset widget, in the Dark look only.                   ← All 9 Widgets
```

- **"This Widget"** (the default) writes the key into the widget's own `[Variables]`, after its `@Include` lines. SkinFileLoader rule 5 says the later key wins.
  - Rule 6 says the first definition inside one file wins. So if the key already appears before the includes in the same section, the writer moves it after them.
- **"All 9 Widgets"** writes the file that defines the value (`Themes/Dark.inc`).

#### 8.1.2 UPDATE SPEED ("How often" pop-up)

| Item | Writes `Update=` | Caption |
|---|---|---|
| Real-time — 40 times a second | 25 | Smoothest animation. Uses the most battery. |
| Smooth — 10 times a second | 100 | Smooth. Good for moving bars and graphs. |
| Every second (standard) | 1000 | Right for clocks and system stats. |
| Every 5 seconds | 5000 | Saves battery. Clocks with seconds will skip. |
| Every minute | 60000 | Saves the most battery. Values change once a minute. |
| Only when it opens | -1 | Never updates by itself. |
| — | | |
| Custom… | | reveals "every [ 0.25 ] seconds" (step 0.05, min 0.016) |

- **Unmatched values** show as **"Custom — 4 times a second"** (below 1 s) or **"Custom — every 2.5 seconds"**. Captions follow the nearest preset.
- **Extra warnings,** shown under the caption:
  - When sound data is present and the speed is 200 ms or slower: **"The sound bars will move in jumps."**
  - When a time format shows seconds and the speed is 2 s or slower: **"The seconds will skip."**
- **Rainmeter Details on:** the caption gains "Update=25".
- **Toast:** "Now updates every second · [Undo]".

#### 8.1.3 ON YOUR DESKTOP

This card is bound to the running widget's `SkinState` through `AppController.changeSettings(of:)`. It writes no file, and each change registers its own named undo step.
- **Stacking** (`alwaysOnTop`):
  - On Desktop (−2): **"Sits on the desktop, behind all windows."**
  - Normal (0): **"Windows can cover it, and it can cover them."**
  - Always on Top (1): **"Stays in front of every window."**
  - A current value of −1 or 2 turns the control into a pop-up with five items: On desktop · Behind windows · Normal · In front of windows · Always in front. The value is kept.
- **Lock position** (`draggable = false`). Caption when on: **"It can't be dragged. Turn this off here or from the widget's right-click menu."**
- **Let clicks pass through.** Caption when on: **"Clicks reach whatever is behind it, so you can't click or drag it. Turn this off here or from Deskset's menu bar icon."**
- **Opacity** slider, 0–100% (stored as 0–255).
- **More Desktop Options:**
  - ☑ Snap to screen edges and other widgets
  - ☑ Keep on screen
  - Fade time [0.25] seconds
  - When the pointer is over it [Do nothing ▾] (Do nothing · Hide · Fade in · Fade out)
- **When the widget isn't running:** **"This widget isn't on your desktop right now."** [Show on Desktop]. The controls are disabled.
- **Undo names:** "Undo Always on Top", "Undo Lock Position", "Undo Change Opacity".

#### 8.1.4 SIZE AND SPACING

- **Size.**
  - [Fits Its Content | Fixed Size]. Fixed reveals "W [217] × H [196] px" (SkinWidth / SkinHeight).
  - Fits Its Content removes them.
- **Behind everything.**
  - With a detected Background layer: the sentence plus [Select It].
  - Otherwise a pop-up: Nothing · A Color · A Picture (BackgroundMode 1 / 2 / 0 with its existing rows).
- **Shared sizes** list every non-colour, non-font variable this widget's layers use in X/Y/W/H/sizes.
  - Humanised names: camelCase split, "W"/"H" expanded ("BarW" → "Bar width").
  - The usage caption comes from ValueUsages.
  - Formula variables are read-only ("217 px · calculated") with [Edit Calculation…].

#### 8.1.5 Disclosures

- **Doesn't Work on a Mac (N).** Plain lines from `skin.issues`. Example: "“Weather” uses a Windows add-on (WebView.dll), so it stays empty on a Mac."
- **About This Widget.** Name · Author · Version · Description · License, in the regular font.
- **More Widget Options:**
  - **Timing:**
    - "Redraw layers [Every update ▾]" (Every update · Every 2nd update · Every 5th update · Custom… · Only once)
    - "Transition speed [10 frames a second ▾]"
  - **Size:**
    - "☐ Resize whenever content changes", caption "Only needed when layers change size while running."
    - "☑ Tight text boxes", caption "Text boxes hug the letters. Recommended."
  - **Dragging:** "Edges that don't drag the widget   Left [0] Top [0] Right [0] Bottom [0] px"
  - **Right-click menu:** "Extra items in the widget's right-click menu" [+ Add Menu Item]. Each existing item reads as a sentence: "“Open Activity Monitor” → Opens “Activity Monitor”", with Edit.
  - **When the widget…:** Opens · Updates · Closes · Gets focus · Loses focus · Wakes from sleep, each "[No action ▾]", or the action summary with "Edit in Code ›" when it can't be shown as a choice.
  - **Looks:** "Band look · 16 bars ›", "Level look · 2 bars ›", "Small text look · 5 texts ›". Clicking one selects its users.
  - **When someone else installs it** (the Default* keys):
    - Caption: "Used the first time someone installs this widget. To change it on this Mac, use On Your Desktop."
    - Rows: Stacking · Lock position · Let clicks pass through · Opacity, then [Copy My Current Settings].
  - **Group names** [   ], hint "e.g. Clocks — used by actions that change several widgets at once".
  - **Other shared values**, with example pop-ups: "Date format [September 24, 2026 ▾]", "Week starts [Sunday ▾]", "24-hour clock ☑".
  - **Colors other widgets use (N)** (shared-file widgets only).

### 8.2 A text layer

**Plain text ("Audio"):**

```
‹ Audio Visualizer
[thumb]  “Audio”
         Text that says “Audio”.
[✎ Edit Text] [👁 Hide] [🔒 Lock] [⋯]

TEXT
  Text      [ Audio                                        ]      placeholder "Type the words to show"
  Font      [Helvetica Neue           ▾] [Semibold ▾] [ I ]
  Size      [ 11 ] pt ⌃⌄
  Color     [■ Title text ▾]
  Align     [ Left | Center | Right ]
  Effect    [ None | Shadow | Outline ]  [■]      ← swatch only when not None
  ▸ More Text Options   capitals, up and down, long text, text before and after, rotation

POSITION AND SIZE
  Position  X [ 14 ] Left ▾      Y [ 12 ]
  Size      Fits the text · 38 × 16             [Set a Size…]
  Align in widget   [⇤ Left] [↔ Center] [Right ⇥]
                    [⤒ Top]  [↕ Middle] [Bottom ⤓]
  Drag it on the canvas, or nudge with the arrow keys (hold ⇧ for 10 px).     ← first 3 selections only

+ Show Live Data…     + Add a Box Behind It…     + Do Something When Clicked…
▸ More Layer Options   redraw timing, group names, show only inside, custom transform
```

**Text showing live data ("48 Hz", "MacBook Pro扬声器").** A SHOWS card appears above TEXT, and Text becomes a token field:

```
SHOWS
  Shows     [Lowest band frequency          ▾]   Go to Live Data ›
            Right now 48 Hz
  Number    [48 ▾]          ← rendered from the live value: 48 · 48.2 · 48.24 · 0.05 k · Custom…
TEXT
  Text      [ (Lowest band frequency) Hz                  ]     ← blue data tag = %1; caption "The blue tag shows the live data."
  …
POSITION AND SIZE
  Position  X (right edge) [ 203 ] calculated ▾    Y [ 15 ]    ← MeterDevice: label follows StringAlign=Right
```

- **Number row.** Hidden when the data is text (device name). Bytes render "3 GB · 3.2 GB · 3,221,225,472". Percent-capable data adds "Percent of range — 83%".
- **Time data** shows **Format** instead: "14:05 · 2:05 PM · 14:05:09 · Wed 24 Sep · September 24, 2026 · Custom…".
- **The blue tag's menu:** Change Live Data ▸ · Number ▸ · Remove.
- **Weight menu:** Thin · Light · Regular · Medium · Semibold · Bold · Heavy (existing `fontWeights`, relabelled). **[ I ]** toggles `StringStyle` Italic, or BoldItalic when the weight is bold.
- **More Text Options:**
  - Capitals [As typed ▾]. Each item is shown in its own case: As typed · UPPERCASE · lowercase · Title Case.
  - Up and down [Top | Middle | Bottom].
  - If it's too long [Keep going ▾]: Keep going · Cut off with “…” · Grow up to a size…
  - Text before [   ] and Text after [   ], which are only meaningful with data.
  - Rotation [0]°.
  - ☑ Smooth edges.
  - Styled parts: N [Edit in Code ›].
  - ☐ Keep spaces at the start and end.
- **More Layer Options:**
  - Redraw [Every update ▾]
  - ☐ Keep options in sync with live data (DynamicVariables)
  - Show only inside [None ▾]
  - When it redraws [No action ▾]
  - Group names [   ]
  - Uses looks: [Small ×] + Add Look
  - Custom transform — Edit in Code › (only when set)
  - Raised edge [None ▾]
- **Click actions.** After "+ Do Something When Clicked…", a **WHEN CLICKED** card appears:
  - "Click [Open an App ▾] [Activity Monitor ▾]". Choices: Nothing · Open a Website… · Open an App… · Open a File or Folder… · Show or Hide a Layer… · Show or Hide Another Widget… · Reload the Widget · Custom Command….
  - "Pointed at [Nothing ▾]" (Change Color To… · Show a Layer… · Custom Command…).
  - "Tooltip [   ]", placeholder "Shown when the pointer rests on it".
  - "▸ More Triggers   right-click, double-click, scroll, pointer leaves".
- **Existing actions** read as sentences:
  - "Opens “Activity Monitor”"
  - "Turns its text Bar color"
  - "Runs 2 commands — Edit in Code ›" (anything the picker can't round-trip is never rewritten)

### 8.3 One bar (after drilling into the group, or the Left channel bar)

```
‹ Audio Visualizer › 16 bars
[thumb]  Bar 6
         Bar showing sound band 6 of 16, filling upward.
[👁 Hide] [🔒 Lock] [⋯]

BAR                                               Look shared with 16 bars
  Shows         [Sound band 6               ▾]   Go to Live Data ›
                Right now 0% — no sound is playing, so the bar is empty.
  Fill          [■ Bar color ▾]
  Empty part    [■ Empty part of bars ▾]  11%
  Fills toward  [ ↑ Up | → Right | ↓ Down | ← Left ]     ← one control = BarOrientation + Flip
  ▸ More Bar Options   picture instead of a color, raised edge, space around it

POSITION AND SIZE
  Position  X [ 74 ] 3 px after Bar 5 ▾      Y [ 36 ]
  Size      W [  9 ] Bar width ▾             H [ 96 ] Bar height ▾
  Align in widget  (six worded buttons)
```

**The Shows menu:**
```
IN THIS WIDGET
  ✓ Sound band 6                0%
    Sound bands ▸  Band 1 … Band 16
    Left channel level          0%
    Right channel level         0%
    Peak level                  0%
NEW ▸   (the Add Live Data catalogue, §5.3)
```
Picking "New ▸ CPU usage" creates the data and assigns it as one undo step, **"Show CPU Usage"**. Toast: "Bar 6 now shows CPU usage · [Undo]".

### 8.4 The group (first click on any band, or the "16 bars" row)

```
‹ Audio Visualizer
[union thumb]  16 bars
               16 bars showing sound bands 1–16, low to high.
[👁 Hide All] [🔒 Lock All] [⋯]
Changes apply to all 16. Double-click a bar on the canvas to change just one.

BARS                                              Look shared with 16 bars
  Each shows    Sound bands 1–16, one each                   (read-only)
  Sound from    [What your Mac plays ▾]   Sound Settings ›   (edits the parent's Port)
  Fill          [■ Bar color ▾]
  Empty part    [■ Empty part of bars ▾]  11%
  Fills toward  [ ↑ Up | → Right | ↓ Down | ← Left ]

SPACING
  Changes the shared sizes these bars use.
  Bar width     [  9 ] px
  Gap           [  3 ] px           ← shown when members are placed "n px after the previous"
  Height        [ 96 ] px           Also moves “48 Hz”.
  Starts at     X [ 14 ] Left ▾     Y [ 36 ]

ARRANGE
  Align in widget  (six worded buttons; moves all 16 together)
```

### 8.5 A shape (Background; System's memory bar)

```
‹ Audio Visualizer
[thumb]  Background
         Rounded rectangle, 217 × 196, behind everything.
[👁 Hide] [🔓 Unlock] [⋯]
Locked, so clicking the canvas picks the layers on top of it.

SHAPE
  Type       [▭ Rounded rectangle ▾]
  Corners    [ Square | Small | Medium | Large ]  [ 10 ] px     ← 0 / 4 / 10 / 16; other values select no segment
  Fill       [ None | Color | Gradient ]  [■ Background panel ▾] 92%
             (Gradient: [■] → [■]   Angle [90°])
  ☐ Outline                    (on → Color [■]  Thickness [1] px  [Solid ▾])
  ▸ More Shape Options   rotate, scale, skew, dashes, line ends

POSITION AND SIZE
  Position  X [ 0 ]   Y [ 0 ]
  Size      W [ 217 ] Width · calculated ▾    H [ 196 ]      ← one-shape layers: W/H edit the shape itself
```

- **Two or more shapes:** a **PARTS** card appears above the rows. It reads "This shape has 2 parts" and lists them:
  - "1  Rounded rectangle — track"
  - "2  Rounded rectangle — fill, length follows Memory used"

  Clicking a part scopes Fill, Outline and Corners to it. **"▸ Exact Geometry"** opens the existing Shape editor, which also provides + / − / ↑ / ↓.
- **One shape:** the card ends with "+ Add Another Shape".
- **A shape driven by data:** an extra row **"Follows [Memory used ▾]"**. Picking another item swaps the data name inside this layer's shape formulas, as one undo step.

### 8.6 Picture / colour block (Peak marker)

```
[thumb]  Peak marker
         A 2 × 27 white block that moves with the peak level.
PICTURE
  Picture    [None ▾] [Choose…]
  Color      [■ Peak marker ▾]  78%              ← colour blocks only
  Opacity    [——————●] 100%
  Fit        [ Stretch | Fit Inside | Fill ]
  ▸ More Picture Options   tint, crop, rotation, flip, tile, grayscale
POSITION AND SIZE
  Position  X [ 36 ] moves with peak level ▾   Y [ 158 ]
```

### 8.7 Graph and gauge

- **Line graph:**
  - Shows
  - Line [■] [1] px
  - Behind the graph [■]
  - New values appear on the [Right | Left]
  - ▸ More Graph Options: grid lines, scale, more lines
- **Bar graph:** Shows · Bars [■] · Behind the graph [■] · ▸ More Graph Options.
- **Gauge:**
  - Shows
  - Color [■]
  - Thickness [4] px
  - Starts at / Sweeps (existing angle control)
  - ▸ More Gauge Options: filled, length, start offset

### 8.8 A live data item (selected in Live Data, or "Go to Live Data ›")

```
‹ Audio Visualizer › Sound from your Mac › 16 sound bands
[〰]  Sound band 6
      How loud one slice of the sound is, from 0 to 100%.
[⋯] Duplicate · Delete · Show in Code

RIGHT NOW
  0%   ▁▁▁▁▁▁▁▁▁▁  last 30 seconds
  No sound is playing.
USED BY
  [thumb] Bar 6                          ← hover outlines it; click selects it
SETTINGS
  Measures      [One sound band ▾]       (Loudness level · Peak level · One sound band · Band frequency · Output device name)
  Band          [ 6 ] of 16
                Band 1 is the deepest bass.
  Listens to    Sound from your Mac      Sound Settings ›
▸ More Live Data Options   lowest and highest value, smoothing, when the value…, replace text, timing
```

- **Parent "Sound from your Mac":**
  - Listen to [What Your Mac Plays | Microphone]
  - Sensitivity slider
  - Rises [Instantly —●— Slowly], Falls [Quickly —●— Slowly]
  - "16 bands from 40 Hz to 16 kHz"
  - ▸ More Sound Options: analysis size, overlap, band count and range
- **Essentials for other types:**
  - CPU: "Processor [All cores ▾]"
  - Memory: "Show [Used | Free | Total]"
  - Network: "Show [Download | Upload | Both]" + "Network [All ▾]"
  - Disk: "Disk [Macintosh HD ▾]" + "Show [Free | Used | Total]"
  - Time: "Format" example chips + "Time zone [This Mac ▾]"
  - Formula: value + "calculated" + [Edit Formula…]
  - Web: "Address"
- **Unused data:** "USED BY — Not used by any layer." [Delete This Live Data] [Show It in a New Text Layer].
- **"When the value…".**
  - Recognised forms show as sentences: "When the value is above 80 → turns “CPU” red".
  - Anything else (multi-clause `&&`/`||`, IfMatch, numbered IfCondition2…) shows as raw text rows with **"Edit as Text"**. It is never rewritten.

### 8.9 Several layers ("48 Hz", "13268 Hz", "L")

```
[stacked thumbs]  3 texts
                  “48 Hz”, “13268 Hz” and “L”
[👁 Hide All] [🔒 Lock All] [⋯]
ARRANGE
  Line up      [⇤ Left Edges] [↔ Centers] [Right Edges ⇥]
               [⤒ Tops]       [↕ Middles] [Bottoms ⤓]
  Space out    [Evenly Across] [Evenly Down]           ← disabled below 3; tooltip "Needs 3 or more layers."
TEXT                                     Changes apply to all 3.
  Font [Helvetica Neue ▾] [Regular ▾] [ I ]   Size [ 8 ] pt   Color [■ Small text ▾]   Effect [None | Shadow | Outline]
SELECTED
  [thumb “48 Hz”] [thumb “13268 Hz”] [thumb “L”]       ← each selects one
```

- **Mixed kinds:** ARRANGE and SELECTED only, with the note **"These layers are different kinds, so only arranging is shared."**
- **Differing values** show **"Mixed"**: a dashed swatch or an empty field with a placeholder.
- **Undo name:** "Change Font Size of 3 Texts".

---

## 9. Canvas affordances

### 9.1 Hover
- A thin accent outline plus a name tag at the layer's top-left, showing the friendly name only ("Bar 6").
- Hovering a group member while the group isn't entered outlines the group, tagged "16 bars".
- The matching row in the sidebar is highlighted (§5.2).

### 9.2 Selection levels (Keynote-style)
- **A click** selects the topmost **unlocked** layer under the pointer.
- **A group member:** the first click selects the whole group. **A double-click** enters the group and selects that member. Further single clicks stay inside the group until you click outside it.
- **Esc** goes up one level: member → group → widget (nothing selected). During a drag, Esc still cancels the drag (existing behaviour).
- **Empty canvas, or a locked layer** (Background): selects the widget. A drag that starts there draws the selection rectangle.
- ⇧-click and the rectangle keep today's multi-selection. ⌘-click selects a group member directly.

### 9.3 Selection tag
- Reads **"Bar 6 · 9 × 96"**.
- Placed **outside** the layer: above it, or below when there's no room, or beside it as a last resort. It never covers the layer. This fixes "Time 127 × 57" covering the date.

### 9.4 Editing text in place
- **Where it applies:** double-click on a text layer whose `Text` is literal, with no `%N`, `#Var#`, `[Section]`, `#CRLF#`, Prefix/Postfix or InlineSetting. [Edit Text] in the identity strip does the same.
- **The editor:** an NSTextField overlay placed exactly over the text, in the layer's font scaled by the zoom, with its alignment.
  - Return writes `Text=` as one undo step, "Edit Text". Esc cancels. Clicking elsewhere commits.
- **An empty new text** shows the placeholder **"Double-click to type"**. It is drawn by the editor only and never written.
- **Data text:** double-click selects the layer and focuses the inspector's token field. One-time caption under the field: **"This text shows live data. Change the words around the blue tag."**

### 9.5 Followers
- While a layer is dragged or nudged, layers placed relative to it (the next layer's `r`/`R`, or `[Meter:X]` references) get a dashed outline and the tag **"Follows “48 Hz”"**.
- A selected, relatively placed layer shows a dotted connector to its anchor.

### 9.6 Locks (editor-only)
- **Storage:** `EditorPreferences.editorLocks[config]`. Nothing is written to the file.
- **The detected Background is locked automatically** unless the user unlocked it (`unlockedBackgrounds`).
- **Locked layers are:**
  - skipped by canvas clicks and rectangles;
  - still selectable from their row, from right-click ▸ Select ▸, and with ⌘A.

### 9.7 Right-click on the canvas
- **Select ▸** lists every layer under the pointer, front first, with thumbnails, including "Background (locked)".
- Then the row menu items (§5.2).
- **On empty canvas:**
  - Widget Settings
  - Paste
  - Fit Widget to Content (only when something is cut off)
  - Zoom to Fit

### 9.8 Placeholders and empty states (editor-only drawing)
- **A bar, graph or gauge with no data** shows a centred chip **"Choose what this shows ▾"**, which opens its Shows menu.
- **Empty widget**, centred in the card:
  > **Your widget is empty**
  > Drag something in from Add, or start with one of these:
  > `[Clock]` `[CPU Bar]` `[Text]`

### 9.9 Silent data
- **Phase 1:** a capsule above the zoom pill, shown when every sound (or other) data item the visible layers use reads 0 or is unavailable for 2 s:
  - **"No sound is playing, so the bars are still. Play something to see them move."** [×]
  - Without permission: **"Deskset can't hear your Mac's sound yet."** [Allow…]
- **Phase 2:** the capsule gains **[Show Sample Data]**, which animates only the editor preview.
  - While sample data is on, the corner badge reads **"Sample data — your desktop widget shows real data"**.
  - It never turns on by itself.

### 9.10 Overflow (agreed behaviour, made exact)

"Outside" means outside the size the widget will have on the desktop. The engine sizes a widget from (0,0) to the right and bottom edges of its visible, non-container layers (plus a `BackgroundMode=0` image); `SkinWidth`/`SkinHeight` override that. Anything at negative X/Y is cut.

1. **Ghost.** Everything outside is drawn at **35%** opacity: one pass clipped to the widget at full strength, then one even-odd-clipped pass inside a transparency layer. The widget edge stays crisp and shadowed. View ▸ **Show Content Outside the Widget** turns the ghost off.
2. **Right/bottom, during a drag:**
   - The widget card grows **live** to `size(for: contentBounds())`.
   - A badge at its bottom-right corner reads **"217 × 196 → 240 × 196"**.
   - New area that the Background layer doesn't cover shows a faint diagonal hatch (transparent on the desktop).
   - After the drop, the size stays grown: the refresh after `perform` recomputes it.
   - Toast: **"Widget grew to 240 × 196 · [Stretch Background] [Undo]"**. [Stretch Background] appears only when a detected Background no longer covers the widget.
3. **Stretch Background** edits the Background's own size, as one undo step "Stretch Background":
   - Literal numbers are replaced.
   - `#Var#` and formula values are offset in place (`(#Width# + 23)`).
   - The shared value itself is never changed.
4. **Left/top, during a drag:** the part past the edge is ghosted and hatched, and a badge reads **"Cut off on the desktop"**.
5. **Left/top, after the drop.**
   - A sticky chip appears at the top centre of the canvas:
     - one layer: **"⚠ “Audio” goes past the left edge. That part won't show on the desktop."** [Fit Widget to Content] [×]
     - several: **"⚠ 2 layers go past the top edge. That part won't show on the desktop."**
   - The same line and button appear in the identity strip, and the row shows ⚠.
6. **Fit Widget to Content** is one undo step, "Fit Widget to Content":
   1. `beginGeometry` runs on every layer with no container (hidden ones included), then `previewGeometry`, shifting by (−minX, −minY), then `endGeometry(keep: true)`.
      - This processes layers in file order through `GeometryEdit.offset`: `#Left#` becomes `(#Left# + 12)`, `[MeasurePeakX]` becomes `([MeasurePeakX] + 12)`, and `r`/`R` followers aren't shifted twice.
   2. After `perform`'s refresh, `controller.moveTo(x: topLeft.x + minX, y: topLeft.y + minY)` moves the desktop window.
   3. A second undo registration in the same event (`groupsByEvent`) restores both the files and the window on ⌘Z.
   - Toast: **"Moved everything 12 px right and the widget 12 px left, so nothing jumps on your desktop. · [Undo]"**.
   - If the widget isn't on the desktop: **"Moved everything 12 px right so nothing is cut off. · [Undo]"**.
7. **Fixed-size widgets** (SkinWidth/SkinHeight set) don't grow. The ghost stays, and a chip reads **"Part of “Clock” is outside the widget's fixed size (200 × 100)."** [Make Widget Bigger] [Fit to Content].
8. **Canvas origin.** The static `SkinCanvasView.margin` (64) becomes an instance `origin` (19 call sites). It stays fixed during a gesture; afterwards it is recomputed to include overflow, and the clip view shifts by the same amount so nothing jumps.
9. **Zoom pill:** ⤢ becomes **"Zoom to Fit"**, and the fit includes ghosted overflow. `componentDropFrame` stops clamping to x, y ≥ 0 on the right and bottom.

### 9.11 Floating selection toolbar (phase 2, thin)

- An in-window capsule using the zoom pill's material, 30 px tall.
- **Placement:** 10 px above the selection tag; below the selection if there's no room; docked at the top of the canvas if neither fits. It never covers the selection. It hides during gestures, while nudging, and in Code mode.
- **Contents,** built from the inspector's own controls:

| Selection | Controls |
|---|---|
| Text | [Edit Text] [Font ▾] [11 pt ⌃⌄] [● ▾] [⋯] |
| Bar, graph or gauge | [Shows ▾] [● ▾] [⋯] |
| Shape | [● Fill ▾] [Corners ▾] [⋯] |
| Group | [16 bars] [● Bar color ▾] [⋯] |

- When the toolbar is present, the selection tag shows only while dragging.

---

## 10. Toasts and undo names

Every toast has plain words, the reach, **[Undo]**, and at most one extra action button.

| Situation | Toast |
|---|---|
| Single layer, shared look | Changed Bar 6 only · [Apply to All 16 Bars] [Undo] |
| Group edit | Changed the 16 bars · [Change ‘Bar color’ Everywhere] [Undo] |
| Shared-file look | Changed “System” only · [Apply to All 6 Widget Titles] [Undo] |
| Widget page colour | Bar color changed on 18 bars · [Undo] |
| All widgets | Font changed in all 9 Deskset widgets · [Undo] |
| Add | Added Clock · Widget grew to 217 × 240 · [Stretch Background] [Undo] |
| Hide | Hid “MacBook Pro扬声器” · [Undo] |
| Desktop | Always on top · [Undo] — Position locked · [Undo] |
| Update speed | Now updates every second · [Undo] |
| Grow | Widget grew to 240 × 196 · [Stretch Background] [Undo] |
| Fit | Moved everything 12 px right and the widget 12 px left, so nothing jumps on your desktop. · [Undo] |
| Reorder guard | Moved “48 Hz” to the front. “13268 Hz” now uses a fixed position, so nothing moved. · [Undo] |
| Shows | Bar 6 now shows CPU usage · [Undo] |
| After ⌘Z | Undid Change Bar Color · [Redo] |

**Undo names:**
- Change Bar Color
- Change Fill of 16 Bars
- Change Font Size of 3 Texts
- Edit Text
- Hide “Audio”
- Hide 16 Bars
- Show CPU Usage
- Add Clock
- Change Update Speed
- Always on Top
- Lock Position
- Fit Widget to Content
- Stretch Background
- Match the Others

---

## 11. What moves where (nothing is lost)

| Today (baseline snapshot) | Now |
|---|---|
| Section names as row titles (Band0…15, LowFreq, Device) | Content names + thumbnails; the section in the tooltip and Rainmeter Details |
| 16 flat Band rows; 23 "Sound level" data rows with monospace code names | One "16 bars" row; one "16 sound bands" row; code names in tooltips |
| Black selected row with invisible name | Accent tint, readable text |
| Header "String meter · 28 × 13 at 14, 136", "Style StyleSmall", `[MeterLowFreq] · Visualizer.ini:353 ↗` | Identity strip sentence; link and looks only with Rainmeter Details; ⋯ ▸ Show in Code |
| Magenta "from StyleX" under every row | One "Look shared with N" badge per card |
| Pills "# 14", "f(x) 136", "#BarGap·" | Number + tag: "Left", "calculated", "3 px after Bar 5" |
| SKIN card: "Refresh every 25 ms", "Background Transparent", "Width/Height auto" | UPDATE SPEED presets; SIZE AND SPACING ("Fits Its Content", "Behind everything") |
| BEHAVIOR card (Resize…, Exact text bounds…, Layers update every…, Transition frames…, Not draggable at…, Groups, Menu item) | More Widget Options with plain names (§8.1.5) |
| Grey "+ Actions", "+ Window defaults" (did nothing live) | Live ON YOUR DESKTOP card; Default* under "When someone else installs it"; actions under "When the widget…" |
| THEME card: variable names, raw "120,200,255,255", checkerboard swatches, other widgets' and internal variables | COLORS AND FONTS by role with counts, on the panel colour; others collapsed; internals only with Rainmeter Details |
| BarW / BarGap / BarH / Left / Width in the Theme card | SIZE AND SPACING shared sizes with usage |
| Decimals / Scale units / Divide by / "percentage of the range" | One Number menu of rendered examples; hidden for text data |
| Icon-only Align row; "Direction" + "Fill from the other end" | Worded buttons; "Fills toward ↑ → ↓ ←" |
| "Style Regular", "Effect None", "Long text", "Keep leading and trailing spaces", "Smooth edges" as top rows | Italic button + Effect row; the rest under More Text Options |
| Hide in the Behavior card, or behind "+ Behavior" | Identity strip [Hide], row eye, context menus |
| "+ Data + Background + Interaction + Behavior" | Outcome buttons; the WHEN CLICKED card |
| Update every / Re-read options / Groups / Container / Transform / On update / Bevel / Padding | More Layer Options (and More Bar Options for Padding/Bevel) |
| "Other options › none" | Hidden when empty; with Rainmeter Details: "Lines Deskset Can't Show as Controls (N)" |
| Toasts "#FontFace# saved to Variables.inc" | Scope toasts with Undo |
| Toolbar "Background" / "+ Library" | "Backdrop" / "+ Add" |

---

## 12. First-run hints

At most **three tips**:
- Each is an in-window capsule with a small arrow, built like `ToastView`, and appears in `snapshot()`.
- Each is shown once, recorded in `EditorPreferences.seenTips`.
- They never appear in self-tests or in snapshots unless `--tip N` is given, and never when `app.presentsWindows` is false.
- Help ▸ **Show Tips Again** resets them.

| Tip | Trigger | Anchored to | Text | Goes away when |
|---|---|---|---|---|
| T1 | First editor open | Canvas (the widget page also shows it as its top line) | "Click anything in your widget to change it. Drag new things in from Add." | First selection, or × |
| T2 | First group selected | The group's identity strip | "These 16 bars change together. Double-click one bar on the canvas to change just that one." | Double-click into a group, or × |
| T3 | First open of the Add tab | Card grid | "Drag any of these onto your widget, or click one to add it below what's there." | First add, or × |

**Teaching that is always present** (not tips):
- card notes (one line per card);
- a plain-sentence tooltip on every control label, with the INI key added under Rainmeter Details;
- canvas placeholders (§9.8) and status banners (§9.9, §5.3);
- the Live Data explanation line;
- empty states;
- the nudge hint, shown for the first 3 selections.

---

## 13. The 10 walkthrough tasks, now

The persona has used Keynote and Canva, has never read docs, and has never heard of Rainmeter.

| # | Task | New flow | Before → after |
|---|---|---|---|
| 1 | Change the accent colour everywhere | Open the editor. Nothing is selected, so the first card is COLORS AND FONTS. Hover **"Bar color · 18 bars"** and the bars pulse. Click the swatch and pick from Custom Color… (live). Toast "Bar color changed on 18 bars · [Undo]". **System:** the blue you see is the top row "CPU graph line and 2 more"; "Apply to: This Widget" is preselected, so nothing changes in other widgets. | likely fails → 2 clicks |
| 2 | Make the title bigger and change its font | Click "Audio" on the canvas. The TEXT card is first: Size ⌃ to 14, Font ▾ Avenir. **System:** "Changed “System” only · [Apply to All 6 Widget Titles] [Undo]". Nothing spreads unless asked. | surprising → 3 clicks, predictable |
| 3 | Find the speaker name and hide it | Layers tab. The row **“MacBook Pro扬声器” · Text · output device name** has its picture. Hovering outlines it; click the row's eye (or [Hide] in the strip, or right-click ▸ Hide). The row dims with an eye-slash. Toast with Undo. Typing "MacBook" in Find also finds it. | hesitant → 1–2 clicks |
| 4 | Move the frequency labels up a little | Click "48 Hz" and press ↑ three times, or drag. "13268 Hz" shows a dashed outline tagged **Follows “48 Hz”** and moves too. Y reads "133 calculated", and the calculation is kept. Past the top: ghost, then the chip [Fit Widget to Content]. | hesitant → direct |
| 5 | Change what a bar shows | Click the spectrum; the group is selected and T2 explains double-click. Double-click the 4th bar: **Bar 4**. Shows ▾ → "Sound bands ▸ Band 6", or "New ▸ CPU usage", which creates and assigns in one step. **System memory bar (Shape):** "Follows [Memory used ▾]". | fails → 3 clicks |
| 6 | Add a clock | "+ Add" (T3). Drag Clock onto the widget; it grows live past the edge ("217 × 196 → 217 × 240"). Or click Clock: it lands in free space below. Toast "Added Clock · Widget grew to 217 × 240 · [Stretch Background] [Undo]". | poor placement → clean placement |
| 7 | Update less often to save battery | Click empty canvas (or the header link "updates 40 times a second"). UPDATE SPEED → "Every second (standard)". The caption warns "The sound bars will move in jumps." | hesitant → 2 clicks |
| 8 | Keep it on top and stop dragging | Widget page → ON YOUR DESKTOP → Stacking "Always on Top", ☑ Lock position. The desktop widget changes at once. Two toasts with Undo. | fails → 2 clicks |
| 9 | Undo a mistake | Toast [Undo], toolbar ↶ (tooltip "Undo Change Bar Color"), or ⌘Z. Desktop settings and Fit undo too. | fine → visible |
| 10 | Find where "Track" is used | Widget page → "Empty part of bars · 18 bars": hover outlines them; click "18 bars" to select them. From any bar, the Empty part row shows the same name, and "Change ‘Empty part of bars’ Everywhere (18 bars)…" is in its menu. With Rainmeter Details, the tooltip shows "Track". | fails → 1 hover |

---

## 14. Build plan

**How the work runs:**
- One short sequential **Step 0** creates the seams.
- Then **four work packages run in parallel**, each on its own branch.
- Each package owns its files. Outside them it only uses the Step 0 APIs, and it may edit existing test files only to update assertions about copy it changed.
- Then an **integration** pass.
- Effort: S ≤ 1 day, M 2–4 days, L ≥ 5 days.

**Shared constraints:**
- Every write goes through `commit` / `perform` / `previewProperty` and is one named undo step.
- `Item.title` stays the section name.
- NSMenu only; every overlay is registered for `snapshot()`.
- Rebuild inputs go into `inspectorInputs()`.
- Clean room.

**Screenshot recipe** (run from the repository root after `swift build`):
```
P=.build/debug/Deskset
$P --snapshot-ui inspector --skins-dir TestSkins    --config 'Audio\Visualizer' --select none --mode design --tab layers --size 1400x1600 --out /tmp/v.png
$P --snapshot-ui inspector --skins-dir DefaultSkins --config 'Deskset\System'    --select none --mode design --tab layers --size 1400x1600 --out /tmp/s.png
```
Add `--dark` for dark mode. Read each PNG and check it against the bullets under each package.

### 14.0 Step 0: seams (lead, S, 1 day, merged to main before branching)

1. **Pure moves** (no behaviour change):
   - `skinOverview`, `variablesCard` and the looks card → new `Sources/Deskset/App/EditorWidgetPage.swift`;
   - `EditorSchema.skinGroups` and `aboutGroup` → new `Sources/DesksetCore/Editor/EditorSchema+Widget.swift`;
   - `LayerCell` → new `Sources/Deskset/App/LayerRowView.swift`;
   - the sidebar half of `refreshLiveValues()` → `EditorSidebar.refreshSidebarValues()`.
2. **Schema fields with neutral defaults:**
   - `Property.level: Level = .more` (`.essential | .more | .quiet`)
   - `Group.summary: String = ""`
   - `Group.moreSummary: String = ""`
3. **Item fields:** `display`, `subtitle`, `symbol`, `seriesMembers: [String]?`, `isLocked`, `isCutOff`. They default to today's values.
4. **Core API stubs** with fallback behaviour:
   - `LayerNaming.layer(_ m: Meter, in: Skin) -> LayerName {title, subtitle, sentence, symbol}` and `LayerNaming.data(_ m: Measure, in: Skin) -> DataName {name, short, subtitle}` (humanised section name for now)
   - `LayerNaming.background(in: Skin) -> String?`
   - `LayerSeries.detect(in: Skin) -> [Series]`, returning `[]`
   - `Skin.valueUsages() -> ValueUsageIndex`, returning empty
   - `Skin.contentBounds() -> SkinRect` and `Skin.size(for: SkinRect) -> SkinSize`, both real and small
5. **App seams:**
   - `SkinCanvasView.hoverHighlight: [String]` and `onHoverChange: ((String?) -> Void)?` (stored only)
   - `InspectorWindowController.overlayViews: [NSView]`, composed into `snapshot()` after the canvas
   - `ToastView.show(_ text: String, actions: [ToastAction])`, which ignores actions for now
   - `LayerMenu.make(for names: [String], in: InspectorWindowController) -> NSMenu`, with today's commands
   - `ColorControl(ctx:)` and `LinkedValueTag(ctx:)`, which wrap today's `SwatchButton` and pill
   - `ScopeResolver.target(section:key:selection:) -> WriteTarget`, which returns today's choice
6. **Preferences** (Codable, tolerant defaults): `seenTips: Set<String>`, `editorLocks: [String: Set<String>]`, `unlockedBackgrounds: Set<String>`. The Settings label is renamed (§4).
7. **CLI flags** accepted and plumbed into a `SnapshotOptions` struct (no-ops until their package lands):
   - `--hover NAME`
   - `--drag NAME:DX,DY` (the gesture is begun and previewed, not ended)
   - `--expert`
   - `--tip N`
   - `--expand NAME`
   - `--edit-text NAME`
   - `--scroll "CARD TITLE"`
   - `--tab add|layers|live`, keeping `library` and `data` as aliases
8. **Empty test suites registered:**
   - App: `FriendlySidebarSelfTests`, `FriendlyWidgetPageSelfTests`, `FriendlyInspectorSelfTests`, `FriendlyCanvasSelfTests`, `FriendlyWalkthroughSelfTests`
   - Core, in `Sources/DesksetSelfTest/`: `LayerNamingTests.swift`, `ValueUsagesTests.swift`, `FormatPresetsTests.swift`, `ContentBoundsTests.swift`

**Acceptance:**
- `swift build` is clean.
- `swift run DesksetSelfTest` and `.build/debug/Deskset --self-test` pass unchanged.
- The two baseline snapshots look the same as before.
- `swift run DesksetSelfTest "Editor: content bounds"`: bounds equal `updateSize` for positive content; negative minX is reported; SkinWidth is respected.

**As built** (what the packages start from; signatures differ from the sketch above where noted):
- Moves: `skinOverview`, `looksCard`, `skinGroupCards`, `variablesCard` and `widgetSectionPage(_:kind:skin:)` (the `[Rainmeter]` / `[Variables]` / `[Metadata]` pages the code's caret can select) are in `EditorWidgetPage.swift`; `skinGroups`, `aboutGroup` and their choice lists (`backgroundMode`, `alwaysOnTop`, `onHover`) in `EditorSchema+Widget.swift`; `LayerCell` in `LayerRowView.swift`. `refreshSidebarValues()` now runs on every live tick, also with nothing selected.
- `Item`: `display` (defaults to `title`), `subtitle`, `symbol`, `seriesMembers`, `isLocked`, `isCutOff`, filled by `present(_:in:)` in `EditorSidebar.swift` with today's values; the row cells read them. Helpers there: `displayName(ofSection:)` (for tags, breadcrumbs, toasts), `isLayerLocked(_:)` (reads `editorLocks`), `layerHoverChanged(_:)` (wired to `canvas.onHoverChange`, empty). `isLayerCutOff(_:)` is in `EditorEditing.swift` (returns false).
- Core: `LayerNaming.layer/data/background`, `LayerNaming.humanized`, `kindNoun`, `symbol(forMeterType:)`; `Series` (`kind`, `members`) and `LayerSeries.detect(in:)`; `ValueUsageIndex` (`values: [Value]`, `Value.source` `.variable` / `.literal`, `uses: [Use(section:key:)]`, `users(ofVariable:)`) and `Skin.valueUsages()`; `Skin.contentBounds()`, `Skin.size(for:) -> SkinSize` (`SkinSize` in `EngineTypes.swift`).
- `ColorControl(ctx:controller:)` and `LinkedValueTag(ctx:controller:asControl:)` / `LinkedValueTag(geometry:key:raw:variable:current:controller:)` are in `EditorControls.swift`, with the pill helpers (`pillValue`, `detachedValue`, `pillMenu`, `editPillInline`, `editPill`, `choosePillMenuItem`) moved there; every color row and every variable / formula value (layout card included) goes through them.
- `ScopeResolver(skin:).target(section:key:selection:variable:) -> WriteTarget` (`scope` `.sharedValue` / `.look` / `.own`, `section`, `key`, `file`) in `EditorPropertyWriting.swift`; `writeProperty` uses it.
- `overlayViews` are drawn after the panes and before the zoom pill and toast; an `NSVisualEffectView` overlay gets the capsule stand-in. `ToastAction(title, handler:)` is in `EditorViews.swift`.
- Preferences: `seenTips`, `editorLocks` (config lowercased → section names lowercased), `unlockedBackgrounds`, and also `showsContentOutside` (View ▸ Show Content Outside the Widget, default on). Settings ▸ Editor: "Show Rainmeter details" with the note "Adds option names, section names and every setting to the editor." (the one-line title did not fit).
- `SnapshotOptions` (in `UISnapshot.swift`) is parsed from the flags and applied by `applySnapshotSidebarOptions(_:)` (EditorSidebar, A: `--expand`) and `applySnapshotCanvasOptions(_:)` (InspectorWindowController, D: `--hover` sets `hoverHighlight` and calls `onHoverChange`; `--drag`, `--edit-text`, `--tip`, `--scroll` not applied yet). `--expert` turns `showIniNames` on before the editor opens. A bad `--drag` or `--tip` exits with status 2.
- Tests: each Friendly suite file starts with a few step-0 seam checks; `FriendlyFixtures.openEditor(_:config:from:)` (in `FriendlyWalkthroughSelfTests.swift`) opens a temporary copy of a repository widget for any Friendly suite.

### 14.1 WP-A: Sidebar (Add · Layers · Live Data) — about 9 days

**Owns:**
- `Sources/Deskset/App/EditorSidebar.swift`
- `LayerRowView.swift`
- new `LayerThumbnails.swift`
- new `LayerMenu.swift`
- `ComponentLibraryView.swift` (copy and hint only)
- `ComponentLibrarySelfTests.swift` (copy)
- `FriendlySidebarSelfTests.swift`
- Core: new `LayerNaming.swift`, `LayerSeries.swift`, `LayerReorder.swift`, `LayerNamingTests.swift`

| # | Item | Effort |
|---|---|---|
| A1 | Row view: 40 pt, custom `NSTableRowView` tint (fixes the black row), title/subtitle, always-visible hidden/locked/⚠, hover eye/lock, FRONT/BACK captions, widget row first, tooltips, accessibility | M |
| A2 | `LayerNaming`: every rule in §6, plus Background detection | M |
| A3 | `LayerSeries` for layers and data; expandable outline; group select / eye / lock / drag as one undo step; expand-on-canvas-select; "Show as Separate Rows" | L |
| A4 | `LayerThumbnails`: `SkinRenderer.drawMeter` cropped at 2x on the panel colour; at most one render per tick, visible rows only; glyph fallback | M |
| A5 | Hover link: sidebar side, and scroll-to-row on `onHoverChange` | S |
| A6 | "Find a layer" search; drag disabled while filtered | S |
| A7 | `LayerMenu` (row and canvas share it): Hide, Lock (editor-only), Duplicate, Delete, Arrange ▸, Select All N, Do Something When Clicked…, Show in Code | S–M |
| A8 | Live Data tab: explanation line, parent/child outline, formatted values, strings in full, Used by links, dimmed unused + Delete, status banners, two-line "+ Add Live Data" menu | M |
| A9 | Add tab copy: "Add", "Pictures", "Live Data" chips, hint, "widget's folder" | S |
| A10 | Reorder guard (`LayerReorder.fixups(skin:moving:to:) -> [Edit]`) with toast | M |

**Acceptance tests:**
- `swift run DesksetSelfTest "Editor: layer names"` on Visualizer.ini:
  - MeterTitle → "“Audio”"
  - MeterLeftLabel → "“L”"
  - MeterLowFreq → "“48 Hz”", subtitle "Text · lowest band frequency"
  - MeterDevice → "“MacBook Pro扬声器”" (with a skin whose device text is empty: "Output device name (empty)")
  - MeterLeft → "Left channel bar"
  - MeterPeak → "Peak marker"
  - MeterBackground → "Background", detected as background
  - MeasureBand5 → "Sound band 6"
  - MeasureHighFreq → "Highest band frequency"
  - MeasurePeakX → "Peak marker position"
  - humaniser: "MeterLeftLabel" → "Left label"
- `"Editor: layer series"`:
  - Visualizer layers give exactly 1 series of 16 (MeterBand0…15); data gives 1 series of 16.
  - The run breaks on a changed look, a changed type, a gap, or fewer than 3.
  - `CPU1, CPU2, CPU3` with different looks is not a series.
- `"Editor: reorder guard"`: moving MeterLowFreq to the front returns an edit that gives MeterHighFreq a fixed `Y=136`. Every frame is unchanged after the refresh.
- `.build/debug/Deskset --self-test "Friendly sidebar"`:
  - The Visualizer layer list has 12 top-level rows; their titles in order equal the §5.2 list.
  - The selected row's rendered background is not dark: mean luminance > 0.6 in light mode, and title-text contrast ≥ 4.5:1 in both modes.
  - Hovering the Device row → `canvas.hoverHighlight == ["MeterDevice"]`, and `inspectorRebuildCount` is unchanged.
  - Clicking the group row → `canvas.selectedNames.count == 16`.
  - The group eye → one undo step, 16 × `Hidden=1`; ⌘Z restores the bytes.
  - Thumbnail renders ≤ 1 per `tick()`; 26 layers render in < 20 ms; the Peak marker uses a glyph.
  - Search "MacBook" → 1 row, and drag validation returns `[]`.
  - Live Data shows 9 top-level rows under the parent, the values "48 Hz", "13.3 kHz" and "MacBook Pro扬声器", and Band 6 1-based. An unused Calc added to a temp copy shows dimmed "Not used by any layer".

**Screenshot checks:**
- `--select none --tab layers` (light and `--dark`): 12 readable rows with thumbnails, a lock on Background, FRONT/BACK captions, and no black row.
- `--select MeterBand5 --tab layers --expand MeterBand0`: the group is expanded, "Bar 6" has the tint, and the parent is visible.
- `--select MeterDevice --tab layers --hover MeterTitle`: the "Audio" row has the hover tint.
- `--select none --tab live`: the outline, banner and formatted values.
- `--select none --tab add --tip 3`: the hint line and tip T3.

**As built** (WP-A; what the integration starts from):
- Core: `LayerNaming.catalog(of:)` names every layer, data item and run at once (`LayerNameCatalog`: `layer(_:)`, `data(_:)`, `name(of:)` / `dataName(of:)` for runs, `series(containing:)`, `users(ofData:)`, `background`); the single calls `layer`, `data`, `series`, `dataSeries`, `background(in:)`, `users(ofData:in:)`, `followedData(of:in:)`, `formulaSource(_:in:)` build it for one question. A formula's short name is its source's ("Swap shape"). `LayerSeries.detect(in:)` (runs need the same type, looks, `Parent=` / `Type=` for data, no container, numbers counting up by one). `LayerReorder.order(of:moving:before:)` and `fixups(skin:moving:to:)` (`to`: the section the block goes before, nil = front) return `LayerReorder.Edit`s (own-section X / Y).
- Layers tab: the list is `.plain` with `selectionHighlightStyle = .none`; `LayerRowView` draws the 18% / 7% tints, `LayerCell` (styles layer, data, widget, caption) the rows. Captions are `Item`s with `kind == nil` (`isGroup`); run rows are `Item`s with `seriesMembers` whose `title` is the first member and whose `children` are the member items. `layerItems` leaves out the widget row and captions. Open runs, data parents and "Show as Separate Rows" are remembered per widget for the window (`SidebarState`, an associated object of the controller, so `InspectorWindowController.swift` has no new stored property).
- Locks: `isLayerLocked(_:)` includes the auto-locked Background; `setLayersLocked(_:locked:)` / `setLayersHidden(_:hidden:)` are one named undo step each ("Lock “Audio”", "Hide 16 Bars") with an Undo toast. `moveLayers(_:before:)` / `moveLayers(_:toListIndex:)` apply the reorder guard ("Move “48 Hz”"). `arrangeTarget(_:_:)` / `arrange(_:_:)` back Arrange ▸.
- `LayerMenu.make(for:in:run:)` (layers; `run` adds Show as Separate Rows / Show as One Row) and `LayerMenu.makeData(for:in:)`; the list's right-click builds them (`SidebarMenuDelegate`). "Do Something When Clicked…" calls `showClickActions(for:)`, which selects the layer and scrolls to a card titled "When clicked" / "Interaction" until C's picker is wired in.
- Live Data (`EditorLiveData.swift`): `LiveDataChoice.catalogue` and `dataSourceMenuItems(expert:_:)`, which the Shows menu's "New ▸" already uses; `addDataSource(_:for:)` takes a `LiveDataChoice` (the `MeasureType` form still works). Items carry `representedObject` = the type name and `identifier` = the plain title. The banner is `liveDataBanner(now:)` (silence counts after 2 s; snapshots count it as settled).
- Hover: rows set `canvas.hoverHighlight` (drawing it is D's); `layerHoverChanged(_:)` tints the row (`LayerRowView.isLinkedHover`) and scrolls to it when the pointer is not over the list.
- Snapshot: `sidebarSnapshotViews()` gives the sidebar's parts to `snapshot()` (the header with the search fields and banner, the list, the empty state).
- Add tab: `EditorComponents.Category` titles are now "Live Data" and "Pictures" (also the Insert menu's section headers), and the image component says "A picture from the widget's folder".

**As built, after review** (WP-A):
- Rows read whole at the sidebar's width. The list is a `SidebarOutlineView` (`InspectorWindowController.outline`): the chevron has a 12 pt column per level instead of the system's 28 pt gutter, and rows run to the tint's edge. Its scroller floats over the rows whatever the Mac has (`OverlayScrollView`, which the canvas uses too): a legacy scroller (a mouse connected, or Show scroll bars set to Always) took 17 pt from them, and a first width 17 pt wider would have taken it from the centre instead. AppKit sets a scroll view's style again whenever that setting changes or a mouse comes or goes, so the style is kept, not set once. The default sidebar width is 262 pt (`EditorLayoutMemory`; was 246; wider would squeeze the code below half of the centre in the default 1180 pt window), where every Visualizer row and every System name and value fits. `LayerCell` is laid out by hand: the name alone on the first line (the state icons at its right), then for data an optional line (the text a data item reads — device names, songs, dates —, "Calculated from peak level" for a formula named after its layer, or "Doesn't work on a Mac"), then the second line; a data row's number sits at the right of the first line under the name, never beside the name. Data names that don't fit wrap onto two lines (the row grows; `heightOfRowByItem`, noted again when the list's width changes). Links and the "Calculated" line have shorter wordings for narrow lists ("Used by “L” and 1 more" → "Used by 2 layers"; "Calculated from memory + swap" → "Calculated"). A row whose words are cut or shortened has them whole in its tooltip, the section name last. Self-test: nothing is cut on either tab at 262 pt, with legacy scroll bars too; names and values of the live data read whole at 246 and 220 pt.
- §5.3's mock shows "Calculated from peak level · used by Peak marker" as one line; as built it is two lines (the line under the name, then "Used by Peak marker").
- Who uses data (`DataUsers`) also counts the sections bangs act on in every action (`[!CommandMeasure …]`, `!EnableMeasure`, `!SetOption`, … — `BangCatalog`'s Meter / Measure / Section parameters, not aimed at another widget), including `[Rainmeter]`'s actions and `[Variables]` (`widget`), and data with actions of its own (`runsActions`: `IfTrueAction`, `OnChangeAction`, `OnUpdateAction`…). Such data reads "Used by the widget" / "Runs actions when it updates" and is neither dimmed nor offered Delete.
- Sizes count as the widget's text layers scale them (`AutoScale=1` → powers of 1024, `2` → 1000) when they agree, else memory in 1024s (Activity Monitor) and disks and networks in 1000s (Finder): System's total memory reads "24.0 GB", as its text and About This Mac do. Disabled data reads "Turned off".
- The "No sound is playing" banner comes after 3 s of silence and goes after 2 s of sound; the clock runs on every tab (Live Data opens with it settled); on a live tick it only comes or goes while the pointer is off the list, sliding the list (`SilenceClock`).
- Hover: a reload of the list (the eye or lock clicked under the pointer) clears the outline the rows put on the canvas and every row's hover, then gives the row under the pointer its hover back (`clearListHover()` / `restoreListHover(at:)`); a late mouse-exit of the previous row keeps the next row's outline; a row view reused while hovered lets go (`prepareForReuse`).
- Thumbnails: a hidden layer (Hidden sets its size to 0) keeps the picture it had while shown (across reloads of the same widget), else shows its kind's symbol in its own colour; colours (as written and as resolved) are in the signature, so `!SetOption … FontColor` redraws; the widget's picture follows every update (at most once per tick); the cache is cleared when another skin object loads.
- "+ Add Live Data" is built again each time it opens (`LiveDataMenuDelegate`), and the rows are rebuilt when View ▸ Show Rainmeter Details changes (group rows then add " · MeterBand0…MeterBand15"). The Shows menu's "New ▸" passes the setting too (one line in `EditorInspector.swift`).
- Deleting a parent deletes the data under it in the same step ("Delete with Its 22 Items"); the toast names the layers that used what was deleted ("Deleted left channel level. Left channel bar used it.").
- AudioLevel RMS with `Channel=Avg` / `Sum` (or none) is "Sound level" (§6.2's "Both channel level" read oddly).
- Outside the package's files: `InspectorWindowController.swift` (the list's class, the default sidebar width) and `EditorInspector.swift` (the Shows menu's `expert:`), one line each.

### 14.2 WP-B: Widget page and shared values — about 10 days

**Owns:**
- `Sources/Deskset/App/EditorWidgetPage.swift` (from Step 0)
- `EditorPropertyWriting.swift`
- `EditorControls.swift`
- `FriendlyWidgetPageSelfTests.swift`
- Core: `EditorSchema+Widget.swift`, new `ValueUsages.swift`, new `WidgetPresets.swift`, `ValueUsagesTests.swift`
- It calls `AppController.changeSettings(of:animated:_:)` unchanged.

| # | Item | Effort |
|---|---|---|
| B1 | `Skin.valueUsages()`: variables through looks, other variables, formulas, bang arguments and Shape strings; literal colours grouped by value; role per use; origin (own file vs shared include); "at least" flag | M–L |
| B2 | COLORS AND FONTS card (§8.1.1): role rows, same-value merge with Show Separately, hover pulse, click-to-select counts, font rows, Show N More | M |
| B3 | Shared-file "Apply to" + override writer after `@Include` (rule 5; moves a key written before the include, rule 6) + Dark/Light captions | M |
| B4 | UPDATE SPEED presets, captions, Custom, context warnings (`WidgetPresets`) | S |
| B5 | ON YOUR DESKTOP on `SkinState`, with its own undo registration, the 5-item fallback, and the not-running state | S–M |
| B6 | SIZE AND SPACING: Fits/Fixed, Behind everything, shared sizes, calculated read-only + Edit Calculation… | M |
| B7 | Disclosures: Doesn't Work on a Mac, About, More Widget Options (all copy in §8.1.5, including Copy My Current Settings) | M |
| B8 | `ColorControl`: panel-backed swatch + %, NSMenu (§7.4); theme picks write `#Var#` | S–M |
| B9 | `LinkedValueTag`: tags and menus (§7.3); variable-edit mode; formula field | M |
| B10 | `ScopeResolver` (§7.5), toast actions "Apply to All N …" (write the wider target and remove the narrow key in one step), ↺ Match the Others | M |

**Acceptance tests:**
- `swift run DesksetSelfTest "Editor: value usages"`:
  - Visualizer: Accent → 18 layers, role BarColor. Track → 18, role "Empty part of bars". Subtle → 5, role "Small text". Text → 1.
  - BarW → 16, BarGap → 15, BarH → 17, Left → 10, Width → 6, calculated.
  - The literal 16,19,28,235 → Background panel; 255,255,255,200 → Peak marker.
  - System: CPUColor, DownColor and AccentColor share one value group whose origin is a shared include.
- `"Editor: widget presets"`:
  - 25 → "Real-time — 40 times a second"; 250 → "Custom — 4 times a second"; 2500 → "Custom — every 2.5 seconds".
  - Stacking −1 → the pop-up form.
- `.build/debug/Deskset --self-test "Friendly widget page"`:
  - The card order is COLORS AND FONTS, UPDATE SPEED, ON YOUR DESKTOP, SIZE AND SPACING, then the disclosures.
  - No visible label contains "Refresh", "ms" or `#`, and no field shows "120,200,255,255" (G3 scan for this page).
  - Hovering the Bar color row → `canvas.relatedNames.count == 18`; clicking "18 bars" → 18 selected.
  - "Every second" writes `Update=1000` as one undo step, and the warning "The sound bars will move in jumps." is present.
  - Always on Top → `SkinState.alwaysOnTop == 1`, file bytes unchanged, ⌘Z → −2.
  - System, "This Widget", on the CPU graph line row:
    - `System.ini` gains `CPUColor=` after `@Include2`;
    - the engine resolves the new value in System and the old one in Network;
    - `Dark.inc` is unchanged.
    - A temp copy with `CPUColor=` written before the includes gets the key moved after them.
  - "All 9 Widgets" writes `Dark.inc` only.
  - Scope:
    - Bar 6's Fill writes `BarColor=` in `[MeterBand5]`.
    - The 16-bar group writes `[StyleBand] BarColor=`.
    - The toast action "Apply to All 16 Bars" writes StyleBand and removes Bar 6's key in one undo step.
    - ↺ Match the Others removes the key.
    - Picking the theme colour "Empty part of bars" writes `#Track#`.
  - One layout in every window: no view the editor window shows has an ambiguous layout (`hasAmbiguousLayout`), with overlay or legacy scroll bars — the widget page (also with every disclosure open, and with Rainmeter Details), the first-run tip, every page of the Visualizer (layers, live data, looks and the widget's sections; the first of a run stands for the rest) with Rainmeter Details off and on, pages of the sample widgets and rows of test widgets that showed the causes below, a toast; and the Manage window's page of details. AppKit settles an ambiguous layout one way or another from one window to the next: the header was 72 pt in some editors built alike and 76 pt in others, and a formula's value was 4 pt wide, out of sight.
    - Across a row NSStackView keeps its insets only at its hugging priority (250), so the header's 48 pt picture took away the 4 pt inset under the taller words; `EditorStyle.holdVerticalInsets` makes a row's insets hold. The shape list's rows keep theirs too (23 pt rows, not 18); a color's opacity under its name has no negative inset (4 pt under the name, as it was drawn).
    - A `NumberControl` ends in a spacer, so it is never put next to another one.
    - The identity strip's words hug their own height when the picture beside them is taller.
    - A card's label | control grid hugs its rows a notch under the controls' own priority, so a control beside a label of two lines or more keeps its height at the top of its row. A stack of lines there hugs its lines a notch under their own (249), so the room is left under its last line (an action's "Edit in Code ›"); `InsetsControl` leaves it under its sides.
    - A stack nested across another stack hugs its views as weakly (250) as the outer one pulls it to its own size: the identity strip's lines that are stacks (the Rainmeter details, a warning) are as wide as the strip, and the Right Now card's sparkline keeps its height beside a value of several lines.
    - In a column too narrow for a row, the views that give way have distinct priorities, so the same one always does: a formula's "calculated" before its value, a `NumberControl`'s unit before its stepper, an option name before the setting's words, a look's name before its brush and ×, a shape's summary before its number, where a line is written before the option's name. A formula's [Edit Formula…] is on the value's line only when the three fit the control column, else on a line of its own; a rule's sentence wraps at the card's width less its "Edit as Text", with either kind of scroll bars.
    - A linked value that is text (Language, Disk) has a field that takes the room its tag leaves; beside the line's spacer it had shrunk out of sight.

**Screenshot checks:**
- Visualizer `--select none --size 1400x2400`, light and dark: the widget page as in §8.1; the Empty part swatch is visible (not a checkerboard).
- System `--select none --size 1400x2400`: the "Apply to" segment with This Widget selected; "Colors other widgets use" collapsed.
- `--select none --expert --size 1400x2400`: variable names in tooltips and labels, and every More open.

### 14.3 WP-C: Selection pages (layers, groups, data, several) — about 11 days

**Owns:**
- `Sources/Deskset/App/EditorInspector.swift`
- `EditorPreviewing.swift`
- `ShapeEditorView.swift` (relabel only)
- `InspectorSelfTests.swift` and `InspectorControlsSelfTests.swift` (copy)
- `FriendlyInspectorSelfTests.swift`
- Core: `EditorSchema.swift` (meter and measure groups), new `FormatPresets.swift`, new `ActionSummary.swift`, `EditorSchemaTests.swift`, `FormatPresetsTests.swift`

| # | Item | Effort |
|---|---|---|
| C1 | Identity strip + breadcrumb + buttons + cut-off line (replaces `header(...)`, `multiHeader()`) | M |
| C2 | Schema pass: plain labels (§3.2), `level` per property (essentials in §8), `summary` and `moreSummary` for every group, quiet keys | M (tedious) |
| C3 | "More {Kind} Options" disclosures with contents, "· N in use", auto-open, set-row dots, all open under `--expert`; "Lines Deskset Can't Show as Controls" | M |
| C4 | Text page: SHOWS card, token field for `%N`, rendered Number/Format menus (`FormatPresets`), Weight + Italic, worded Align, Effect, Capitals in own case, "X (right edge)" / "X (center)" | M |
| C5 | Bar page: Fills toward, Empty part, look badge, "Right now" line; Shows menu with IN THIS WIDGET / NEW ▸ create-and-assign ("Show CPU Usage") | M |
| C6 | Group page: BARS + SPACING cards (edit shared sizes, with the "Also moves …" caption), Sound from | S–M |
| C7 | Shape page: Type, Corners presets, Fill segmented, Outline, PARTS only when ≥2, "Follows [data ▾]" | M |
| C8 | Picture, Graph, Gauge pages (§8.6–8.7) | S–M |
| C9 | Live data page: RIGHT NOW + sparkline, USED BY, per-type SETTINGS, 1-based band, unused state, "When the value…" sentences with raw fallback | M |
| C10 | Several layers: worded Line up / Space out, shared-kind card with Mixed, SELECTED chips | S–M |
| C11 | Outcome buttons; WHEN CLICKED picker; action sentences (`ActionSummary`); never rewrites what it can't parse | M |

**Acceptance tests:**
- `swift run DesksetSelfTest "Editor: schema levels"`:
  - Every meter and measure group has ≥ 1 essential property.
  - No card has more than 5 essentials, except Text with 7.
  - Every group with non-essential properties has a `moreSummary`.
  - The G3 banned words don't appear in any essential label.
- `"Editor: format presets"`:
  - 13268.00443 → "13268", "13268.0", "13.3 k"; 3221225472 bytes → "3 GB", "3.2 GB", "3,221,225,472".
  - `%H:%M` renders "14:05" at 14:05.
- `"Editor: action summaries"`:
  - `["/System/Applications/Utilities/Activity Monitor.app"]` → "Opens “Activity Monitor”"
  - `["https://example.com"]` → "Opens example.com"
  - `[!ToggleMeter MeterTitle]` → "Shows or hides “Audio”"
  - Two unrelated bangs → "Runs 2 commands"
- `.build/debug/Deskset --self-test "Friendly inspector"`:
  - MeterTitle: strip "“Audio”" / "Text that says “Audio”."; no source link unless expert; TEXT rows = Text, Font, Size, Color, Align, Effect.
  - MeterDevice: X label "X (right edge)" = 203; no Number row.
  - MeterLowFreq: Y tag "calculated"; ↑ nudge keeps `#BarH#` in the written Y.
  - MeterHighFreq: Y tag "Same top as “48 Hz”".
  - MeterBand5: X tag "3 px after Bar 5", value 74; card badge "Look shared with 16 bars".
  - Group: Height edit writes `BarH=100`, with the caption "Also moves “48 Hz”".
  - A temp copy with `StringCase=Upper` on the Title → "More Text Options … · 1 in use", opened, with Capitals showing "UPPERCASE".
  - With `--expert`, every disclosure is open.
  - Selecting 2 texts → Space out is disabled, with tooltip "Needs 3 or more layers."
  - Shows ▾ New ▸ CPU usage on Bar 6 → one undo step "Show CPU Usage" adds `[MeasureCPU…]` and `MeasureName=`.
  - WHEN CLICKED "Open a Website…" writes `LeftMouseUpAction=["https://example.com"]`.
  - An existing unparseable action stays byte-identical after an unrelated edit.

**Screenshot checks:**
- `--select MeterTitle`, `--select MeterLowFreq`, `--select MeterDevice`: §8.2.
- `--select MeterBand5 --size 1400x1600` and `--select MeterBand0,MeterBand1,…,MeterBand15` (the group): §8.3–8.4.
- `--select MeterBackground`: §8.5 with the lock note.
- `--select MeterPeak`: §8.6.
- `--select MeterLowFreq,MeterHighFreq,MeterLeftLabel`: §8.9.
- `--tab live --select MeasureBand5`: §8.8.
- System `--select MeterRAMBar` (or the memory-bar section name): PARTS and Follows.
- Every page again with `--dark`.

**As built (WP-C):**
- Files: the pages are in new `EditorSelectionPages.swift` (state, identity strip, card builder with "More", Position and Size), `EditorLayerPages.swift` (text, bar, shape, picture, graph, gauge, group, several, WHEN CLICKED, the Shows menu, the token field) and `EditorDataPage.swift` (live data). `EditorInspector.swift` keeps the rebuild, the controls per kind and the helpers the widget page uses (`header`, `groupCard`, `moreGroups`, `otherOptionsCard`), unchanged for it. Core: `FormatPresets.swift`, `ActionSummary.swift` (with `ClickAction`), and in `EditorSchema.swift` the cards (`Group.moreTitle`, `Property.partOf` for a control that holds several options), the live data catalogue (`liveDataCatalogue`, `extraLiveDataTypes`) and the copy check `engineWord(in:)`.
- Position and Size draws its own grey tags (`geometryTag`: "Left", "Left + 6", "calculated", "3 px after …", "Same top as …", "moves with …", with the menus of §7.3) after a number field; `LinkedValueTag(geometry:)` is no longer used there. Property rows still use `ColorControl` and `LinkedValueTag(ctx:)`.
- Group writes go through `ScopeResolver.target(…, selection: members)`; single-layer writes through `writeProperty` (so §15.2 follows B's resolver).
  - The group's Fill and Empty part rows carry the members in `PropertyContext.selection`: `writer(ctx)` writes them with `writeSeveral`, and the color panel previews on all of them (`previewSeveralColor`). At integration, pass `selection: ctx.selection` to B's `ColorControl(ctx:controller:selection:)` in `kindControl`.
  - "Starts at X / Y" and ARRANGE move the whole run (`moveRun`, one undo step "Move 16 Bars"): a position they all take from a look that is theirs alone moves the look (`[StyleBand] Y=`); otherwise each member's own value moves, links kept, and members placed after the one before (`#BarGap#R`) follow by themselves.
- Shape pages: the Fill and Outline colors are §7.4-style controls (name, ▾ menu with theme colors, opacity, a rim for dark cards). A Shape layer's option defined by a look in a file other widgets include (`StyleTrack` in the shared Styles.inc) is written on the layer (`writeShapeOption`), never into that file; B's resolver does the same for every option.
- The Number menu renders its choices in the base the text uses (`FormatPresets.base(ofAutoScale:)`: System's memory text stays in 1024s); a combination none of them writes reads as a normal "Custom — …" choice.
- The token field's typing has an undo stack of its own (emptied when the editing ends), and a rebuild while it is edited keeps the typed text.
- Until the sidebar work lands, runs are also found by the rules of §5.2 on the page itself (`fallbackLayerSeries`, `fallbackDataSeries`, `groupSeries(for:)`), and names fall back to `EditorStyle.describe`.
- Hooks for the other packages: `requestFitWidgetToContent()` (the strip's Fit button → D's `fitWidgetToContent()`), `focusInspectorTextField()` ([Edit Text] and the canvas's data-text hand-off), `selectParentLevel()` (Esc), `setLayersLocked(_:_:)` / `setLayersHidden(_:_:)`.
- Self-tests: `openEditor…` fixtures that need every control open insert `"open/more:*"` into `inspectorState.disclosures` (every More open).

### 14.4 WP-D: Canvas, window chrome and overflow — about 11 days

**Owns:**
- `Sources/Deskset/App/SkinCanvasView.swift`
- `EditorEditing.swift`
- `EditorViews.swift` (ToastView buttons, ZoomPill)
- `InspectorWindowController.swift` (toolbar, keys, snapshot)
- `MainMenu.swift`
- `CommandLineTools.swift`
- `EditorWindowSelfTests.swift` and `StudioReviewSelfTests.swift` (margin and copy updates)
- new `CanvasOverlays.swift` (chips, badges, tip capsules, status capsule)
- new `InlineTextEditor.swift`
- `FriendlyCanvasSelfTests.swift`
- Core: `Engine/Skin.swift` (`contentBounds` and `size(for:)` only) and `ContentBoundsTests.swift`

| # | Item | Effort |
|---|---|---|
| D1 | Selection levels (§9.2): group-first click, double-click drill-in, Esc up, empty or locked click → widget, locked layers skipped | M |
| D2 | Hover drawing (`hoverHighlight` + 30% veil), friendly name tags, selection tag outside the layer, `onHoverChange` | S |
| D3 | Overflow ghost at 35% + View toggle | M |
| D4 | Live right/bottom growth + badge + hatch; instance `origin` replacing `margin` (19 sites); no clamp on right/bottom drops | L |
| D5 | Left/top hatch + badge + sticky chip; Fit Widget to Content (geometry path + `moveTo` + one grouped undo); fixed-size chip; Stretch Background | L |
| D6 | In-place text editing (`InlineTextEditor`) + [Edit Text] hook + data-text hand-off | M |
| D7 | Follower outlines and anchor connector | S |
| D8 | Canvas right-click (`LayerMenu` + Select ▸ + empty-canvas items) | S |
| D9 | Placeholders ("Double-click to type", "Choose what this shows ▾"), empty-widget starters, silent-data / permission capsule | S–M |
| D10 | Tips T1–T3 + Help ▸ Show Tips Again (`seenTips`) | S |
| D11 | Toasts with action buttons, toolbar ↶ ↷ with names, "+ Add", "Backdrop", View / Help / Settings menu items, "Reload Widget" | S–M |
| D12 | Click-to-add placement in free space below the content (`insertComponent`) + growth toast | S |
| D13 | Finish the CLI flags: `--hover`, `--drag`, `--edit-text`, `--tip`, `--scroll` | S |

**Acceptance tests** (`.build/debug/Deskset --self-test "Friendly canvas"`):
- **Selection levels:**
  - A click at Band3's centre → the selection is 16 names; a double-click → `["MeterBand3"]`; Esc → 16; Esc → `[]`.
  - A click on the Background's empty area → `[]` (widget page); a drag there draws a rectangle.
- **Right/bottom growth:** dragging MeterTitle 60 px right past the edge during the gesture:
  - the card width is > 217 and the badge reads "217 × 196 → …";
  - a pixel outside the old width shows the title at full strength.
  - After mouse-up and refresh, `skin.width` has grown. Esc during the drag restores 217.
- **Left edge and Fit:**
  - Dragging MeterTitle to x = −12 → the chip text equals the §9.10 copy, and the row `isCutOff` is true.
  - Fit → `contentBounds().minX == 0`; every top-level meter's frame is +12; the window's top-left is −12; Band1–15 keep `#BarGap#R`; Peak X becomes `([MeasurePeakX] + 12)`.
  - One ⌘Z restores the file bytes and the window position.
- **Fixed size:** a temp copy with `SkinWidth=200` doesn't grow, and shows the fixed-size chip.
- **In-place editing:**
  - Double-click the Title → the field holds "Audio"; typing "Sound" + Return → `Text=Sound`, one undo step "Edit Text".
  - Esc leaves the bytes unchanged.
  - Double-click on HighFreq focuses the inspector token field instead.
- **Followers:** dragging MeterLowFreq marks MeterHighFreq as a follower.
- **Tips:** shown once in a presenting app and never in self-tests; `--tip 1` renders T1.
- **Add placement:** a click-added Clock's frame has y ≥ max content Y + 8 and doesn't intersect any existing frame.
- **Toasts:** the toast view has an "Undo" button whose action calls `undoManager.undo()`.

**Screenshot checks:**
- `--select MeterBand5 --hover MeterBand5`: the group hover outline plus tag, no tag over content.
- `--select MeterTitle --drag MeterTitle:60,0`: grow badge, card grown.
- `--select MeterTitle --drag MeterTitle:-30,0`: ghost + hatch + "Cut off on the desktop".
- After a scripted drop: the chip at the top centre.
- `--select MeterTitle --edit-text MeterTitle`: the field aligned over the text at 178%.
- `--select none --tip 1`: T1 capsule.
- The toolbar shows ↶ ↷, "+ Add" and "Backdrop" (`--size 1600x1000`).

### 14.5 Integration (lead, 2–3 days, after all four merge)

1. **Merge order:** Step 0 → A → B → C → D (any order works; resolve test-file copy conflicts by keeping the newest copy).
2. **Wire the cross-package seams:**
   - canvas tags, breadcrumbs, toasts and undo names all use `LayerNaming`;
   - the canvas right-click uses `LayerMenu`;
   - the group SPACING card uses `ValueUsages` captions;
   - the identity-strip Fit button calls D's `fitWidgetToContent()`.
3. **Run the G3 banned-word scan over every default state:** nothing selected, and every layer and data item of Visualizer, System and Clock.
4. **Update the docs:**
   - point `docs/editor-design.md` §2–3 at this document;
5. **Walkthrough test** `.build/debug/Deskset --self-test "Friendly walkthrough"`. It performs the 10 tasks programmatically on temp copies of Visualizer and System, checks each outcome in §13, and checks that every step's control is reachable without opening a disclosure:
   - task 1: 18 BarColor users changed, and System's Network is unchanged;
   - task 3: `Hidden=1` on MeterDevice;
   - task 7: `Update=1000`;
   - task 8: SkinState is updated and the file bytes are unchanged.

**As built (integration):**
- **Merged** A → B → C → D. Duplicated helpers became one each: `titleCase` (EditorPropertyWriting), `undoToastAction` (EditorEditing), `focusInspectorTextField` (InlineTextEditor; the token field of data text first), `scrollInspector(toCard:)`, `layersLabel(_:title:)` (runs by `LayerNaming`, other selections by kind: "Hide 2 Texts"), `setLayersHidden` / `setLayersLocked` (strip, list, menus and canvas), plural words (`LayerNaming.kindPlural`). The live data list's name phrase is `namesPhrase`, so the widget page's `usersPhrase` counts ("5 texts") are its own.
- **One live data catalogue**, in Core (`EditorSchema.liveDataCatalogue`, options in writing order, no "Swap used": SwapMemory is memory and swap, under Extras, named "Memory and swap used" everywhere). "+ Add Live Data", every Shows menu's New ▸ and the canvas's "Choose what this shows ▾" (now the Shows menu itself) list it through the sidebar's `dataSourceMenuItems`.
- **Seams:** canvas tags, groups and toasts use `LayerNaming` / `LayerSeries`; the canvas right-click uses `LayerMenu`; the group SPACING card's "Also moves …" and every position tag count a shared value's users as the widget page does (`ValueUsageIndex.reach`); the identity strip's cut-off line uses the canvas's edges and calls `fitWidgetToContent()` (or `makeWidgetBigger()` past a fixed size); [Edit Text] edits in place on the canvas (data text: the token field); the data page's ⋯ menu, Delete and Show in a New Text Layer are the Live Data tab's, and its USED BY counts what the tab counts (actions and the widget's own actions included: "Runs actions when it updates."); Esc in the list or inspector goes up a level (`selectParentLevel`). The toast view is the one record of its buttons (`toastActions`; `chooseToastAction` clicks them).
- **Colour names:** every colour control names a colour as the widget page does — a shared colour by its row's role ("Empty part of bars"), a colour written directly by the role of its uses ("Background panel"), a row of several roles by the shared colour's own name ("Track color"), else "Custom". When the name and the opacity don't fit beside the swatch, the opacity goes under the name ("11% opacity"), so names read whole. Shape swatches are drawn on the panel colour too.
- **Picking live data** in Shows is one step "Show Sound Band 6" with the toast "Bar 4 now shows sound band 6"; widening a look in a file other widgets share reads "Apply to All 6 Widget Titles".
- **Stretch Background** is offered for the layer that was the Background before the widget grew (the 90% rule no longer finds it once the widget has grown by more than a tenth). Until it is stretched, that layer is named by its shape and isn't locked automatically.
- **G3** is one check, `EditorSchema.engineWord(in:)` (the widget page's `WidgetPresets.isEngineText` asks it): the §3.3 words plus "plugin", `#…#`, `[Section]` and R,G,B(,A) numbers; the widget's own words in curly quotes are exempt. The Friendly walkthrough scans every default state of Visualizer, System and Clock (nothing selected, every layer, every run, every data item, the Add tab, both lists opened all the way, the toolbar, the layer and data menus). Fixed from its findings: actions that are set now read as sentences with "Edit as Text" (a look's `#CURRENTSECTION#` hover reads "Turns its text back to its usual color"), "Included with the Widget" (font menu), "This widget has no looks", "This widget isn't loaded.", the picture menu's "In the Widget's Folder" / "Shared Files", the header's live line in words, unknown add-ons as "Data from WebView", picture names without `#@#`.
- **Walkthrough, as built:** on System the blue "CPU graph line and 1 more" row is among the six colours shown as the page opens, not the top row (rows sort by how many layers use them: "Label text and 3 more" comes first; "and 1 more" because only this widget's roles are named).
- **Screenshot recipe:** `--drag MeterTitle:60,0` moves the title 60 px, which keeps it inside the 217 px Visualizer; `--drag MeterTitle:222,0` takes it 60 px past the right edge (badge "217 × 196 → 277 × 196").
- **App self-test harness:** each suite's editors are closed and its autoreleased objects drained at its end. The run never returns to the run loop, and on macOS 26 every NSButton keeps a SwiftUI attribute graph; with all four packages' suites the table filled and aborted the run.

### 14.6 Phase 2 (after integration, separate packages)

| Item | Effort |
|---|---|
| Floating selection toolbar (§9.11) | L |
| Sample data preview (editor-only value override; must never reach the desktop `Skin`) + [Show Sample Data] | L |
| Colour palettes with hover preview (`Skin.preview`) | M |
| Text styles Heading / Label / Value / Caption in Add and on the Text page | M |
| Shape tiles (Card, Pill, Circle, Line) | S–M |
| "Use One Font Everywhere…" | S |
| Rename layer (stored as a `; @label …` comment above the section) | M |
| "When the value…" builder with raw fallback; "When the widget…" builders beyond pop-ups | M |
| Dark/Light colour-set switch, only when an include path is built from a variable | S–M |

---

## 15. Open decisions (defaults chosen so building can start)

1. **"Widget" instead of "skin"** throughout the Studio. Default: yes. The menu bar and Manage window follow later.
2. **Editing one layer that uses a shared look changes only that layer** by default, and the toast offers "Apply to All N". Default: yes. This changes today's behaviour, which writes to the look.
3. **The full-size Background is locked automatically in the editor.** This is editor state only, and one click unlocks it. Default: yes.
4. **Sample data is opt-in, in phase 2.** Phase 1 only explains why the widget is still. Default: yes.