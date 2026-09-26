# Deskset Skin Studio — editor design (v3)

Design brief: the editor should not feel like an INI key/value editor. Goals:
1. A **component library**: drag common components onto the canvas; clicking a component shows its configuration.
2. **Fool-proof controls**: enumerations and structured values get proper controls (Shape type must be a menu —
   typing `aaaa` silently breaks the meter). No "INI parsed into KV text fields".
3. A **built-in code editor** side by side with the WYSIWYG canvas, and a **setting** to choose the code editor
   (built-in or an external app; external = clicking opens that app). Today files open in the Launch Services
   default for `.ini`, and nothing lets the user change it.

Research inputs: Apple HIG (panels, split views, sidebars, toolbars, settings, pop-up buttons,
segmented controls, toggles, steppers, sliders, color wells), Figma UI3 / Sketch / Keynote / Xcode Library / Webflow
Add panel / Framer property controls, NN/g (dropdown vs radio, defaults, placeholders), Android Studio Code | Split |
Design, Xcode canvas, external-editor settings (GitHub Desktop, Tower), a verified editor table, and a catalog of 313
options (37 enums, 63 booleans) derived from Deskset's engine + the public manual only (clean room).

The approved visual style stays: dot-grid canvas with shadowed skin, cards, color swatches, floating
zoom pill, toasts.

## 1. Window

```
┌ Toolbar ─────────────────────────────────────────────────────────────────────────────────────┐
│ [◧] System · Deskset\System        [+ Library]   [ Design | Split | Code ]   [Open in ▾] [◨]  │
├──────────────┬───────────────────────────────┬───────────────────────┬────────────────────────┤
│ Library      │                               │ System.ini ▾  [Sect ▾]│ Inspector              │
│ Layers  Data │   canvas (dot grid, skin)     │ 1 [Rainmeter]         │ (selection / skin)     │
│ ──────────── │                               │ 2 Update=1000         │                        │
│ search…      │                               │ …  code pane          │                        │
│ ▢ Text  ▢ …  │          ( − 100% + ⤢ )       │                       │                        │
└──────────────┴───────────────────────────────┴───────────────────────┴────────────────────────┘
```

- Three panes; the centre is itself split canvas | code. Every pane can be hidden (sidebar ⌃⌘S, inspector ⌥⌘I,
  code via the mode control; View menu mirrors all). Thin dividers, min/max widths, split autosave.
- **Mode control** `Design | Split | Code` (toolbar, View menu ⌃⌘1/2/3, ⌥⌘↩ toggles code). It only affects
  canvas vs code; sidebar and inspector are independent. Code on the right by default (View ▸ Code Below).
- When the code-editor setting is an **external app**, the mode control shows only Design and the toolbar button
  reads **"Open in <App>"** (icon + name); live reload picks up saves.
- The app switches to the `.regular` activation policy while an editor or the Settings window is open (so the
  menu bar with File/Edit/View/Insert exists) and back to `.accessory` when both are closed.

## 2. Left sidebar: Library | Layers | Data

> **Superseded (2026-09-25).** The sidebar is now `[ Add | Layers | Live Data ]` as specified in
> [`docs/editor-friendly.md`](editor-friendly.md) §5–6 (content names and pictures instead of section names, repeated
> layers folded into one row, hover linked with the canvas, editor-only locks, the one live data catalogue). The text
> below records the v3 design it replaced; where the two disagree, `editor-friendly.md` wins.

- **Library** (new, first tab; toolbar "+ Library" and ⇧⌘L select it and focus search): search field, category
  chips (Text, Data, Graphs, Gauges, Shapes, Images), grid of cards. A card = live thumbnail rendered by the real
  renderer (cached), plain name, one-line description, data badge (CPU, Memory…).
  - Drag a card onto the canvas: the canvas shows a ghost of the component's default size at the current zoom with
    snap guides; drop inserts it centred on the pointer, selects it, one undo step "Add CPU Bar".
  - Click (or Return) inserts: after the selected layer (10 pt below it) or in the middle of the visible canvas.
  - Components are original (EditorComponents); each has a category, default size, description, SF Symbol.
- **Layers**: unchanged model (front first, drag to reorder, eye). A pinned first row "Skin" (skin name, gear
  icon) selects the skin itself (replaces the bottom "Skin Settings" button, which the HIG advises against).
- **Data**: data sources in plain words (48 types incl. plugins), live values; "+ Add data source" menu at the top.

## 3. Inspector (fool-proof)

> **Superseded (2026-09-25).** The inspector is now the one-column "Keynote-calm" design of
> [`docs/editor-friendly.md`](editor-friendly.md) §7–8: an identity strip instead of the header, cards of 3–5
> essentials each ending in "More {Kind} Options", the widget page (colors and fonts by role, update speed presets,
> On Your Desktop, size and spacing), colour controls and linked-value tags instead of pills, and the rule that an
> edit writes the narrowest place covering the selection. The control-per-kind table and the fidelity rules below
> still describe the controls the new pages are built from; everything else in this section is history.

Cards stay, but inside each card controls sit in a **label | control grid** (NSGridView: right-aligned label,
control fills), numeric pairs on one row (X Y / W H). Order: header → Position & Size → Data → type appearance
(Text / Bar / Graph / Gauge / Image / Shapes) → Background → Interaction → Other options (collapsed).

Control per value kind (schema-driven; `EditorSchema.Kind`):

| kind | control |
|---|---|
| bool | checkbox with a positive title ("Smooth edges"); any non-zero = on |
| enum ≤ 4 | segmented control (icons + tooltips or short text) |
| enum 5–15 | pop-up with plain titles, engine default marked "(default)" |
| alignment9 (StringAlign) | two segmented controls: horizontal L/C/R + vertical T/M/B |
| number | compact field (number formatter, min/max, unit) + stepper where useful |
| percent255 (ImageAlpha, alpha) | slider + "%" field (0–100% ↔ 0–255) |
| angle(storage: degrees/radians) | degree field + circular slider for orientations; radians written as `(Rad(n))` |
| color | swatch → system color panel (alpha); unset = empty swatch |
| font | font menu (faces in their own face; skin fonts first; System Font; Windows names show the Mac substitute) |
| insets (Padding) | four small fields L T R B with a link toggle |
| image | thumbnail + pop-up of images in the skin folder/@Resources + "Choose…" (copies into @Resources, writes #@#…) |
| sectionRef(measure/meter/style) | pop-up of existing sections by friendly name; for data sources "New Data Source" at the bottom (created and used in one undo step) |
| multiRef (MeterStyle) | token list limited to existing styles |
| text / format / formula | text field; format fields get a combo of presets and a live preview line |
| action | text field (bang builder is a later step) |
| shapes (Shape meter) | the Shape editor, §4 |

Rules:
- **Invalid current values are never silently replaced.** An enum whose file value is unknown shows it as the
  selected, disabled first item with a warning ("“aaaa” is not a shape type — nothing is drawn") plus the valid
  choices. Matching is case-insensitive and understands aliases (Left = LeftTop …).
- A value that is a whole `#Var#` or a formula is shown as a **pill** (purple, name + resolved value). Its menu:
  Edit Variable (writes the variable), Detach (writes the literal resolved value), Show in Code. Editing the
  control on a `#Var#` value writes the variable (current behaviour).
- Values inherited from a MeterStyle show a small "from StyleX" origin badge; editing writes where defined
  (current behaviour); the row menu adds "Override on this layer".
- Conditional visibility from the schema (Effect color only when Effect ≠ None, gradient fields only when a
  gradient is on…). Hidden values keep their stored text.
- INI option names are not printed next to labels; they are in the tooltip, or visible when Settings ▸ Editor ▸
  "Show INI option names" is on.
- Continuous controls (slider, circular slider, stepper hold) preview live (`Skin.preview`) and write once on
  mouse-up / idle — one undo step.
- "Other options" (collapsed) lists only options the schema does not cover, with "Edit in Code".
- Controls update in place on refresh when the structure did not change (keep focus, scroll, open menus).

## 4. Shape editor

A Shape meter's `Shape`, `Shape2`, … are shown as a **list of shapes** in the "Shapes" card (+ / − / reorder;
reordering renumbers and rewrites Combine references). Each shape expands to:
- **Type** pop-up with icons: Rectangle, Ellipse, Line, Arc, Curve, Path, Combine. Changing type carries geometry
  over (rect bounds ↔ ellipse centre/radii ↔ line diagonal) and keeps modifiers.
- **Geometry** fields per type (Rectangle: X Y W H + corner radius (linked X/Y); Ellipse: centre + radius (linked);
  Line: start, end; Arc: start, end, radii, direction (segmented), size (segmented); Curve: start, control points,
  end; Path: path option pop-up (named option of the meter); Combine: parent + list of (operation, shape)).
- **Fill**: None | Color | Linear gradient | Radial gradient. Gradients edit the named option (angle + stops).
- **Stroke**: checkbox (off = StrokeWidth 0), color, width, dash (Solid | Dashed | Dotted | Custom), caps and
  join (collapsed).
- **Transform** (collapsed): rotate (circular slider + °), scale X/Y (+ flip buttons), skew, offset.
- Values that are formulas / variables stay pills; parsing never loses tokens. An unparseable shape string shows
  "This shape uses syntax the visual editor can't show" + Show in Code.

Core model (`DesksetCore/Editor/ShapeModel.swift`, public, round-trip tested on the default skins):
`ShapeSpec.parse(_ raw: String) -> ShapeSpec?`, `spec.text` (canonical `Type a,b,c | Modifier x | …`, params kept
as written), `ShapeSpec.Kind` (rectangle, ellipse, line, arc, curve, path, path1, combine), `ShapeSpec.Modifier`
enum with typed payloads, `GradientSpec` for named gradient options.

## 5. Code editor

- Built on TextKit 1 `NSTextView` (explicit `usingTextLayoutManager: false`), line-number ruler, find bar,
  smart substitutions off, monospaced font (size in Settings, ⌘+ / ⌘−).
- **Highlighting** from a line tokenizer in Core (`IniHighlighter`): section headers, keys, `=`, values,
  `Meter=`/`Measure=` types, `#Var#`, `[Section:X]`, bangs `[!…]`, comments, formulas' parentheses; applied as
  temporary attributes per edited paragraph.
- **Jump bar**: file pop-up (main .ini + every @Include file of the skin) and section pop-up.
- **Selection sync**: selecting a layer / data source scrolls the code to its section and tints the block (no
  focus steal); resting the caret in a section (150 ms) selects that layer / data source. Origin-tagged to avoid
  loops.
- **Commit model** (disk file stays the source of truth): typing marks the buffer dirty (dot in the jump bar) and
  registers on the code view's own undo manager. The buffer commits after ~0.8 s idle, on ⌘S, on focus loss and on
  file switch, through `perform("Edit Code", files: [url])` — one EditorFileChange step on the window's undo stack,
  then the skin refreshes. Before any visual edit commits, a dirty buffer is committed first. After a visual edit
  or an external change — including the skin's own `!WriteKeyValue` and saves elsewhere with live reload off — the
  clean buffer reloads keeping caret and scroll. A commit never writes over a change made on disk since the buffer was
  read: it asks (Keep My Edits / Use the File on Disk / Decide Later).
- Encoding (UTF-8 / UTF-16LE BOM / ANSI) and line endings are preserved byte for byte; Return inserts the file's
  dominant line ending. A character the file's ANSI code page cannot hold offers conversion to UTF-16LE with BOM.

## 6. Settings (⌘,) and editor routing

- **Settings window** (App menu "Settings…" ⌘,; "Manage Skins…" moves to ⇧⌘,): toolbar panes **General | Editor**.
  Editor pane:
  - "Edit code with:" pop-up — **Deskset (built-in, side by side)** (default for new *and* existing users) ─ detected
    editors with icons (curated bundle-id table ∪ apps claiming .ini, installed only) ─ "System default (<App>)"
    ─ "Other…" (NSOpenPanel for .app). Helper text says what will happen ("Opens at the selected line").
  - "Open skins in:" Design / Split / Code (built-in only).
  - "Show INI option names in the inspector" checkbox. Code font size.
  - "Refresh the skin when the file is saved elsewhere" (live reload).
- Stored in `AppState` (state.json) so self-tests never touch the user's defaults.
- **`CodeEditorRouter`** (new file) is the single entry point: `open(file:line:)`.
  - built-in: open the skin editor for the skin that owns the file (main or included), switch to Split, reveal the
    line. A skin that is not loaded is loaded first.
  - external: VS Code forks via `Contents/Resources/app/product.json` (`<urlProtocol>://file<path>:<line>`),
    Zed `zed://file…`, BBEdit `x-bbedit://open?url=…&line=`, TextMate `txmt://…`, Nova `nova://open?path=&line=`,
    JetBrains `idea://open?file=&line=`, MacVim `mvim://…`, Sublime / CotEditor / Xcode via their bundled CLI,
    otherwise open the file. URLs are sent to the chosen app with `NSWorkspace.open(_:withApplicationAt:)`.
  - Never calls `setDefaultApplication`. The log file keeps opening in the system default app.
- Call sites routed through it: skin menu "Edit in <app>" (shown only when an app is chosen; the menu's "Edit Skin…"
  always opens the Studio), Manage window "Edit", `!EditSkin`, editor "Show in Code" /
  source links. `#CONFIGEDITOR#` resolves to the chosen external app, or to Deskset when built-in (Deskset then
  routes opened files to the router instead of the skin installer — except .rmskin packages, ZIP archives and
  folders). With the built-in editor, a text file no running skin reads opens in a Deskset code window (never the
  Launch Services default); other files open in their default app.

## 7. Out of scope for this round

Bang/action builder, renaming layers with reference rewriting, data-source drag onto layers, dropping library items
into the code pane or between Layers rows, autocompletion, diagnostics squiggles, rendering from an unsaved buffer.
