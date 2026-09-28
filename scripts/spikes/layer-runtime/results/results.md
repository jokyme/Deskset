# H1: a skin as many Core Animation layers instead of one bitmap — results

Measured on 2026-09-27 and 2026-09-28 with the spike in this folder (`run.sh`, then `python3 summarize.py`). Every
number below comes from a JSON file next to this one; each section names its files. Questions 1–7 and the side checks
of the H1 experiment are answered here; question 8 (a `CARenderer` probe on the CI runners) is a separate step.

On 2026-09-27 Deskset itself stopped drawing skins with `draw(_:)` (A below) and started drawing each skin window into
a bitmap of its own that becomes the view's layer contents, keeping pictures of meters that did not change (B below).
The plan compares the layer runtime with A; this document compares it with both, and calls B "today".

## Conditions

- MacBook Pro Mac16,8, Apple M4 Pro (14 cores), 24 GB; macOS 26.5.2 (25F84). `env.json`.
- One display: the built-in Liquid Retina XDR ("Built-in Retina Display", 1512 × 982 pt at 2×), color space
  **"Color LCD"** (the panel's own profile, Display P3 primaries: sRGB red is (0.9175, 0.2004, 0.1385) in it), 8 bits
  per sample, EDR headroom 16 (1 in use). No external and no sRGB display was attached, so the 1× rows, the "sRGB
  screen" rows and the screen-change part of question 7 are **not measured**.
- The Mac was not idle: other builds and self-test runs (one of them up to 6 cores), a browser, the iOS Simulator and
  desktop apps ran at the same time, and WindowServer used 45–56 % of one core with none of the spike's windows on
  screen. ⟪LOAD⟫ Every CPU phase records the 1-minute load average at its start and end; numbers taken with a load
  above 8 are marked **provisional**, and combinations with a provisional round were repeated when the load allowed
  (the tables say which).
- Memory: normal memory pressure (level 1) during every run of this campaign, 1–2 GB free, swap 8 of 9 GB in use.
  (A first campaign ran under memory pressure level 2; its pixel, color and flip results were identical, its memory
  numbers are not used here.)
- `phys_footprint` counts only pages that are mapped into the process. A `CGImage` made from a bitmap context keeps
  the context's pages by copy-on-write and is charged again only when something in the process reads it
  (`probes.json`: 8 such images of 9.77 MB each added 0.34 MB, and 78.75 MB once CoreGraphics drew them; a live
  9.77 MB context counted 9.78 MB). CA hands images to the window server without reading them (question 6). So memory
  is also given as the uncompressed bytes of the bitmaps the layers hold ("layer bitmaps").
- The spike logs the kind of context every draw gets. Describing a context with `CFCopyDescription` costs 2.76 µs
  and **leaks 214 bytes per call** on macOS 26.5 (`probes.json`: +20.39 MB per 100,000 calls; a color space's
  description leaks nothing), so the log describes each context type once and then only counts.
- Screen capture was allowed for the process running the spike (checked with `CGPreflightScreenCaptureAccess`, never
  requested). Only the spike's own windows are read back (`CGWindowListCreateImage` for one window,
  `CGWindowListCreateImageFromArray` for several).

## What the spike does

A standalone AppKit program (`Sources/`, `swiftc -O`); it does not use Deskset's code. `Content.swift` draws synthetic
skins with CoreGraphics and CoreText the way Deskset's renderers draw meters: the default skins' StylePanel (rounded
rectangle, 270° linear gradient clipped to the path, 1 pt border, highlight line), String meters (FontSize at 96 DPI,
semibold and regular weights, right alignment, tracking, one subtitle with AntiAlias=0), an Image meter scaled with
high-quality interpolation, bars and rounded rectangles at fractional coordinates, a Line graph (1.5 pt, round
joins), a Histogram, translucent pills, tracks and cards, and a ring gauge whose stroke is filled with a gradient.

| widget | size (pt) | groups / base tiles at 2× | what changes |
|---|---|---|---|
| System (the default System skin plus per-core bars, a pill, an icon, an AntiAlias=0 subtitle) | 260 × 196 | 19 / 38 (base: the panel) | 12 groups every second, 2 every 5 s, 1 every minute |
| design (clock, date, ring gauge, weather icon, translucent card) | 360 × 360 | 8 / 25 | 2 groups every second (seconds, ring), 3 more every 10–60 s |
| visualizer (32 gradient bars, title, frame counter) | 260 × 120 | 34 / 22 | 33 groups every frame at 60 Hz |

`Partition.swift` implements the plan's `ComponentPartition`: element boxes are the ink rounded out to whole device
pixels, the base is the leading run of elements covering ≥ 50 % of the window (drawn once into a window-sized sRGB
bitmap), overlapping boxes are merged until stable, and the rest of the window is cut into row-band tiles that show
the base bitmap through `contentsRect` with nearest filtering. No element's ink escapes its box (checked for every
element at 5 ticks, `q5.json` → `inkEscapes`).

Ways a skin reaches the screen (`Runtime.swift`):

| name | what |
|---|---|
| **A** | today: a flipped view draws the whole skin in `draw(_:)` on the main thread (a display-list context) |
| **E1** | one layer; the skin thread calls `setNeedsDisplay` + `displayIfNeeded`, `draw(in:)` paints the whole skin |
| **EP** | the partition: base tiles plus one E layer per group (base pixels copied in with `.copy`, then the group's elements moved by whole pixels) |
| **EPx** | EP, but the dirty groups are drawn at their window position into one window-sized scratch bitmap (base restored under their boxes first) and each group layer copies its box out of it |
| **EP16** | EP in today's window color space with `RGBA16Float` layers and the base bitmap drawn in that space at 16-bit float (the combination closest to A, question 4) |
| **D1** | one layer whose `contents` is an sRGB, 8-bit, premultiplied IOSurface the skin thread draws into (pool of up to 3, skipping `isInUse`) |
| **DP / DPx** | the partition with IOSurface groups and an IOSurface base (DPx: through the scratch bitmap) |
| **OVE / OVD** | control: the panel in one layer and everything else in one layer on top (shares pixels), with E layers or our own bitmaps |

Layered modes use the plan's view structure: panel → flipped container → ContentHost (layer-backed, `isFlipped`,
`wantsUpdateLayer`, draws nothing) → `contentRoot` (created and owned by the runtime) → tiles and groups. Every layer
gets `contentsScale`, `contentsFormat = .RGBA8Uint` (unless stated), no actions; each skin commits from its own thread
(run loop, 8 MB stack) inside `CATransaction.begin/commit` followed by `flush`. The first `displayIfNeeded` happens in a
second transaction after the tree was committed (see question 4). "Default window" means `NSWindow.colorSpace` left
alone (the screen's; what Deskset does today), "sRGB window" means `NSWindow.colorSpace = .sRGB`.

Pixel comparisons: the window read back by the window server (8-bit BGRA in the display's color space, 520 × 392 px for
System), channel by channel; "max" is the largest channel difference in 8-bit levels, the percentage is the share of
pixels with any difference. Also composited over an opaque backdrop window (what a person sees over the desktop).
Two consecutive captures of every window were identical.

## Answers at a glance

| # | question | answer (details in the sections below) |
|---|---|---|
| 1 | partition vs one E layer vs A, read back from the screen (built-in XDR display, 2×, "Color LCD" ≈ Display P3) | **sRGB window: partition vs one E layer max 1 in 7 px (0.003 %)**, all from CoreGraphics' whole-pixel translation of curved paths; **0** when the groups are drawn through a window-sized scratch bitmap. Default window: max 1 in 48 % (the sRGB base bitmap vs E contexts in the display's space), max 1 in 7 px once the base is drawn in the window's space. One E layer vs today's A: max 6 in 84 % (default window); anything rendered in 8-bit sRGB vs today's A: max 10 in 87 % (the panel alone: max 2). Overlapping layers (reproduced): max 2–4 in 7–25 %. |
| 2 | E vs D | **Identical (0) in an sRGB window**; in the default window max 9 in 54 % (E follows the window's color space, D's surfaces are sRGB). Partition with IOSurfaces vs one IOSurface: max 1 in 7 px; through the scratch bitmap 0. Memory and CPU: see 3. |
| 3 | memory and CPU at 2× | ⟪Q3GLANCE⟫ |
| 4 | the `draw(in:)` context and formats | A bitmap context (`kCGContextTypeBitmap`, data in this process) **in the window's color space** ("Color LCD" by default, sRGB in an sRGB window, Display P3 in a P3 window), 8 bpc for `RGBA8Uint`, 16 bpc float for `RGBA16Float` (extended sRGB in an sRGB window), `kCGContextTypeCoreAnimationAutomatic` when no format is set; A gets a display list. Closest to today's A: **`RGBA16Float` in the default window (identical)**; `RGBA8Uint` in an sRGB window (the plan's format) is max 10 in 87 % from A and identical to D and to A in an sRGB window. |
| 5 | gradients cut at box edges (pure CG) | 270° StylePanel gradient cut by a 100 × 30 pt box: max 1 in 70.8 % of the box; **64.4 % reproduced exactly** (298 box positions on a 1 pt grid); over all positions median 67.9 %, 0–84 %. Box at the panel's top left, translation only, solid translucent panel: 0. **Whole-window base bitmap + whole-pixel sub-rectangles: 0.** |
| 6 | base tiles sharing one image | **Counted once**: 61 tiles cost what one layer with the image costs (this process within 0.08 MB; WindowServer +12–13 MB either way; in the default window CA's color-converted copy, +19.6 MB, is made once for all 61 tiles, but once per image for separate copies: 8 copies +156.6 MB). **Read back byte for byte**: 0 differing pixels offscreen (`CARenderer`) and on screen (vs one layer). |
| 7 | ContentHost flipping | All markers in place in 5 of 5 captures over 4 resizes; **AppKit wrote to `contentRoot` 0 times** (25 times to a layer-hosting root). Screen change not tested (one screen). |
| – | layers committed off the main thread | 65 layers at 60 Hz from a skin thread: 179–180 of 180 frames reached the screen, 0 of 13,428 captures (12 runs) showed two commits mixed, and frames kept reaching the screen while the main thread was blocked (53–54 committed, 54–56 distinct frames seen during 3 × 300 ms blocks). |
| – | glass following a moving element | Every frame a main-thread frame at 60 Hz: **the 50 ms bound holds** (no patch waited longer than 50.7 ms; with 120 ms main-thread stalls 5–7 of 216 frames per run were reclaimed). No drift while stalls stay under 50 ms (0 of about 1,300 captures per run); 120 ms stalls leave the glass up to 6 pt (two frames' movement) behind the element in 6.3–7.1 % of the captures. |
| – | refresh by swapping windows | ⟪SWAPGLANCE⟫ |
| – | click-through on transparent pixels | Needs a person: steps at the end. |

⟪DECISION⟫

## 1. Partitioned layers vs one E layer vs A on screen (`q1.json`, crops in `crops/`)

System widget, tick 7, all modes on screen at once (19 groups, 38 base tiles).

| comparison | default window | sRGB window |
|---|---|---|
| EP (partition) vs E1 (one E layer) | max 1, 48.18 % (98,207 px) | **max 1, 0.003 % (7 px)** |
| EPx (partition drawn through the scratch bitmap) vs E1 | max 9, 56.58 % | **0** |
| E1 vs A in the same window | max 6, 84.32 % | **0** |
| E1 vs today's A (default window) | max 6, 84.32 % | max 10, 87.24 % |
| A in an sRGB window vs today's A | – | max 10, 87.24 % |
| OVE (overlapping E layers) vs E1 | max 2, 6.80 % (inside group boxes 11.28 %) | max 3, 12.15 % (20.15 %) |
| OVD (overlapping own bitmaps) vs D1 | max 4, 24.94 % (31.88 %) | max 3, 12.15 % (20.15 %) |

- **In an sRGB window the partition equals one E layer**, except 7 pixels that differ by 1, all inside group boxes.
  They come from CoreGraphics itself: drawing the same curved path moved by whole device pixels does not give
  identical pixels (question 5). Drawing the groups through a window-sized scratch bitmap (EPx) removes them:
  **0 differing pixels**, also over the backdrop.
- **In the default window it does not**: the E layers' contexts are in the display's color space (question 4), so
  copying the sRGB base bitmap into a group converts it in CoreGraphics while the base tiles are converted by the
  window server; the two conversions round differently (max 1 in 48 % of the pixels, over the backdrop max 2 in
  48.11 %). Drawing the base in the window's color space fixes it (EP + base in window space vs E1: max 1, 7 px,
  `q4-default.json`). EPx in the default window is worse (max 9, 56.58 %): its scratch bitmap is sRGB, so its groups
  carry sRGB pixels next to E contexts in the display space.
- **A vs E**: in the default window E1 differs from today's A by up to 6 levels in 84 % of the pixels (167,947 pixels
  by 1, 3,896 by 2, 40 by 3–6): today's A is rendered in the window's color space at a higher precision than the
  8-bit E backing store (question 4: an `RGBA16Float` E layer equals A exactly). Anything rendered in sRGB at 8 bits
  (E1 or D1 in an sRGB window, A in an sRGB window) differs from today's A by up to 10 levels in 87 % (167,661 by 1,
  9,880 by 2, 214 by 3, 67 by 4–7, 2 by 8–10); the pixels outside the group boxes (the panel alone) differ by at most
  2. Over the backdrop: max 6 in 81.15 % (E1) and max 10 in 80.97 % (sRGB). In an sRGB window, A, E1 and D1 are
  identical.
- The window server's color matching differs from CoreGraphics' by 1 level: every sRGB-rendered mode differs from the
  offline sRGB reference converted by CoreGraphics into the display space by max 1 in 14.91 % of the pixels.
- **Overlapping layers** (reproduced): putting the panel and the content in two layers that share pixels changes up to
  2–4 levels in 7–25 % of the pixels, inside the content's boxes 11–32 %; the partition does not share pixels and has
  none of this.
- Crops (top left of the System widget, 200 × 76 px): `q1-A.png`, `q1-E1-srgb.png`, and difference maps (red =
  different) `q1-diff-E1-vs-A.png`, `q1-diff-E1-srgb-vs-A.png`, `q1-diff-EP-vs-E1.png` (default window),
  `q1-diff-OVD-srgb-vs-D1-srgb.png`.

## 2. E vs D (`q1.json`; memory in question 3)

| comparison | default window | sRGB window |
|---|---|---|
| D1 vs E1 | max 9, 53.81 % | **0** |
| DP (IOSurface base) vs D1 | max 1, 0.003 % (7 px) | max 1, 0.003 % (7 px) |
| DPx vs D1 | **0** | **0** |
| DP with a CGImage base vs D1 | max 1, 5.71 % (base tiles: 14.39 % of their pixels) | – |
| D1 vs today's A | max 10, 87.24 % | max 10, 87.24 % |

D's pixels do not depend on the window's color space (D1 is identical in both windows): the IOSurfaces are sRGB and
the window server converts them. E matches D exactly once the window is sRGB. A base given as a CGImage instead of an
IOSurface is converted differently from the same pixels in an IOSurface (max 1 in 14 % of the tile pixels).

## 3. Memory and CPU at 2× (`cost/*.json`, `wscpu/*.json`, `wsmem/*.json`, `memtrace/*.json`, `summary.json`)

⟪Q3⟫

## 4. Color: the `draw(in:)` context, formats and color spaces (`q4-default.json`, `q4-srgb.json`, `q4-p3.json`)

**The context `draw(in:)` gets is a bitmap context in the window's color space**, not sRGB and not the display list A
gets (`kCGContextTypeDisplayList`). Its depth follows `contentsFormat`:

| window color space | `contentsFormat` | context (skin thread) | backing store after 3 more frames |
|---|---|---|---|
| default (the screen's "Color LCD") | RGBA8Uint | bitmap, Color LCD, 8 bpc | `BGRA8888`, 2 buffers |
| default | RGBA16Float | bitmap, Color LCD, 16 bpc float | `RGBAh`, 2 buffers |
| default | not set | `kCGContextTypeCoreAnimationAutomatic` | `RGBA16` (16-bit integer), 2 buffers |
| sRGB | RGBA8Uint | bitmap, sRGB, 8 bpc | `BGRA8888`, 2 buffers |
| sRGB | RGBA16Float | bitmap, extended sRGB, 16 bpc float (some group layers: sRGB, 16 bpc float) | `RGBAh`, 2 buffers |
| sRGB | not set | automatic | `BGRA8888`, 2 buffers |
| Display P3 | RGBA8Uint / RGBA16Float / not set | Display P3, 8 bpc / 16 bpc float / automatic | `BGRA8888` / `RGBAh` / `RGBA16`, 2 buffers each |

Small group layers (the 14 × 28 px core bars and a 66 × 34 px value) ended up with a `CGImage` as `contents` instead
of a backing store after a few frames; CA does this on its own.

If an E layer is displayed in the same transaction that adds it to a window's tree (before the window's context knows
the layer), its first `draw(in:)` runs on the skin thread in sRGB and CA then draws it **again on the main thread** in
the window's color space (1 of 1 E1 layers, 10 of 19 EP groups). Committing the tree first and displaying in the next
transaction avoids it; the spike does that everywhere else.

Which combination brings E closest to today's A (System widget, one E layer; A = default window):

| E layer | vs today's A |
|---|---|
| default window, RGBA16Float | **0** (identical) |
| Display P3 window, RGBA16Float | max 1, 0.27 % |
| default window, format not set (RGBA16) | max 5, 1.58 % |
| sRGB window, RGBA16Float (extended sRGB) | max 4, 11.61 % |
| default window, RGBA8Uint | max 6, 84.32 % |
| sRGB window, RGBA8Uint (= D1, = A in an sRGB window) | max 10, 87.24 % |

The partition in the combination closest to A (default window, RGBA16Float, base bitmap drawn in the window's color
space at 16-bit float): max 1, 0.004 % (8 px) against E1 and against today's A. With RGBA16Float but an sRGB 8-bit base:
max 2, 77.16 %. The partition matches the single layer whenever the base bitmap is in the same color space and depth
as the E contexts (7–10 px of translation noise in every window color space tried); otherwise 48–77 % of the pixels
differ by 1–2.

## 5. Gradients cut at box edges (pure CoreGraphics, `q5.json`)

260 × 200 pt at 2×, sRGB 8-bit premultiplied; the StylePanel (radius 16, PanelTop → PanelBottom, border and highlight)
drawn into a bitmap that covers only a 100 × 30 pt box vs drawn whole.

| case | result |
|---|---|
| 270° gradient, 100 × 30 pt box at (80, 85) | max 1, **70.83 %** of the box's pixels (gradient alone, no border: the same) |
| same box, 180° / 225° | max 1, 70.10 % / 73.01 % |
| 270°, the box at every position on a 2 pt grid (6,966 positions) | 0–84.0 %, median 67.9 %, always max 1 |
| 180° / 225°, same scan | median 68.5 % / 69.5 % (0–82.6 % / 0–83.2 %) |
| full-width 260 × 30 pt boxes, every row (86 positions) | median 70.0 % (0–84.1 %) |
| the review's **64.4 %** | reproduced: 298 box positions on a 1 pt grid give exactly 64.4 % at 270° (the review did not record its box) |
| box at the panel's top left (100 × 30, and 260 × 100) | **0** |
| the whole panel moved 10 pt (translation only) | **0** |
| solid translucent rounded panel, cut | **0** |
| same bitmap, clipped to the box (rectangle or even-odd) | max 1, 70.83 % (as cutting) |
| same bitmap, even-odd hole around the box (compared outside it) | **0** |
| **whole-window base bitmap, box copied out in whole pixels** (`.copy`, no interpolation) | **0** |

The gradient's pixels depend on where the clip's bounding box starts: a box that starts at the panel's top left, or a
hole that leaves the bounding box unchanged, gives 0; any other start changes about two thirds of the pixels by 1.

Whole partitions composed offline (base bitmap + each group's bitmap copied in) vs one bitmap, worst of ticks 0, 1, 7,
60, 61:

| widget | groups / tiles | partition vs one bitmap | where (summed over the 5 ticks) | naive (panel redrawn per group, clipped) | scratch bitmap |
|---|---|---|---|---|---|
| System | 19 / 38 | max 1, 16 px (0.008 %) | CPU graph + fill 45 px, 2 core bars 1 px each | max 1, 33.66 % | **0** |
| design | 8 / 25 | max 1, 10 px (0.002 %) | ring gauge + its text 28 px | max 1, 26.50 % | **0** |
| visualizer | 34 / 22 | max 1, 1 px (0.001 %) | one gradient bar | max 1, 26.85 % | **0** |

The remaining pixels come from moving the drawing by whole device pixels: each group's elements drawn at their place in
a window-sized bitmap vs drawn into the group's own bitmap (no base involved) differ in the same groups by nearly the
same counts (`translationOnly`: System 46 px, design 28, visualizer 1). They are curved paths (a stroked polyline with
round joins, arcs, small rounded rectangles); the groups made only of text, the icon image or plain rectangles moved
exactly. Rounding the boxes' device origin down to a multiple of 2–64 pixels does not remove them (System: 46 px at
1–16 px grids, 38 px at 32–64; design 26–30 px; the visualizer's 1 px disappears from a 16 px grid). Drawing every
group at its window position into one window-sized scratch bitmap and copying the box out (`scratchWindowBitmap`) is
exact by construction: **0** for all three widgets and all ticks, and 0 on screen (EPx, DPx in question 1).

## 6. Base tiles sharing one image (`q6/*.json`)

A 1600 × 1600 px base image (9.77 MB uncompressed), shown in an 800 × 800 pt window as 61 tiles (the window minus 20
group boxes), each tile a layer with `contents` = the same image, its own `contentsRect`, nearest filtering.

**Read-back** (`q6/readback.json`, 800 × 600 px image, 13 group holes, 40 tiles):
- Offscreen through `CARenderer` (Metal device "Apple M4 Pro", sRGB, the layer tree in a 2× transform): tiles vs the
  image **0** differing pixels (CGImage contents and IOSurface contents alike), the holes are fully transparent, one
  layer with the whole image vs the image 0.
- On screen: tiles vs one layer showing the whole image, same window: **0** in the default window and in an sRGB
  window. Tiles vs the image converted by CoreGraphics into the display space: 0 in the default window, max 1 in
  15.13 % in an sRGB window (the window server converts, see question 1).

**Memory** (`q6/memory-*.json`; median of 3 open / close cycles, a fresh image each cycle; `phys_footprint` of this
process after the window was on screen for 2 s; WindowServer's footprint from `top`, 1 MB steps):

| what the 800 × 800 pt window shows | this process, sRGB window | this process, default window | this process, sRGB window, random pixels | WindowServer open / close step (all 9 cycles) |
|---|---|---|---|---|
| nothing (empty window, the reference) | +0.08 MB | +0.13 MB | +0.08 MB | 0 / 0 MB |
| one layer with the whole image | +0.19 MB | +19.66 MB | +0.22 MB | +12…13 / −12…−13 MB |
| **61 tiles sharing one CGImage** | **+0.13 MB** | **+19.64 MB** | **+0.14 MB** | **+12…13 / −12…−13 MB** |
| 61 tiles sharing one sRGB IOSurface | +9.89 MB | +9.86 MB | +9.94 MB | +12…13 / −12…−13 MB |
| 61 tiles, each a `CGImage.cropping` of the image | +3.22 MB | +19.91 MB | +3.20 MB | +12…13 / −12…−13 MB |
| control: 8 tiles, each with its own copy of the image | +0.50 MB | +156.56 MB | +0.34 MB | +12…13 / −12 MB |

(The first of the 3 cycles is higher in every row, by 3–22 MB, and is not the median: allocator growth of the first
cycle; the random-pixel column's first cycle also holds the 9.8 MB buffer the noise was made in.)

- **Counted once**: 61 tiles that share one image cost what one layer with that image costs, in this process (within
  0.08 MB in every column) and in WindowServer (+12…13 MB either way), and read back byte for byte.
- The clearest case is the default window: CA converts an sRGB `CGImage` into the display's color space inside this
  process, **+19.6 MB for a 9.77 MB image** (an 8-byte-per-pixel copy: 1600 × 1600 × 8 bytes = 19.5 MB), once for all
  the tiles that share it and again for every separate image (8 copies: +156.6 MB = 8 × 19.5). An IOSurface tagged
  sRGB is not converted, and nothing is converted in an sRGB window.
- In an sRGB window the image itself does not show up in this process (one image, 61 tiles and 8 copies all within
  0.5 MB of the empty window): `phys_footprint` does not charge a `CGImage` made from a bitmap context until the
  process reads it (see Conditions), and CA hands the image to the window server without reading it. So the "copies"
  control only shows what separate copies cost where CA touches them (the default window). An IOSurface the process
  wrote is charged (+9.8 MB).
- WindowServer grew by 12–13 MB for any content in this 1600 × 1600 px window (0 for the empty window), however many
  layers, images or copies showed it.

## 7. ContentHost flipping (`q7.json`)

ContentHost as the plan has it (layer-backed `NSView`, `isFlipped = true`, `wantsUpdateLayer`, no drawing), the
runtime's `contentRoot` added to its layer on the main thread, content added from a skin thread: a marker image at the
top left (red over dark red), one at the bottom right (blue over dark blue), and an E layer whose `draw(in:)` paints a
green bar along the top of its bounds. The window was resized four times on the main thread with the top-left corner
fixed (300 × 200 → 400 × 300 → 250 × 150 → 300 × 420 → 520 × 180 pt); after each resize the skin thread set
`contentRoot.bounds` and moved the bottom marker. Every write to `contentRoot` that the runtime did not make was
logged with its thread.

- All 5 captures had every marker exactly where it belongs (red half at (10, 10, 60 × 15) pt, blue half at
  (W − 70, H − 40), green bar at (100, 60, 80 × 10)): nothing upside down.
- **AppKit never wrote to `contentRoot`** (0 writes in the whole run); `contentRoot.isGeometryFlipped` stayed false and
  the ContentHost's own layer (`NSViewBackingLayer`) reported `isGeometryFlipped` false as well: the flip comes from
  the view.
- `draw(in:)` gets a flipped context under the flipped ContentHost (CTM a = 2, d = −2): the runtime must not flip again.
- Control, the draft-1.0 design (the runtime's layer as a layer-hosting view's root): AppKit wrote to it on the main
  thread 25 times — on each resize `geometryFlipped`, `anchorPoint`, `setNeedsLayout`, `bounds`, `position`, and while
  attaching `removeFromSuperlayer`, `hidden`. When the runtime set `geometryFlipped = true` on that root itself,
  AppKit set it back to false. The content still ended up in the right place in both controls, so the review's
  upside-down groups were not reproduced here, but the main thread does write the root's geometry, which would race
  with a skin thread writing the same layer.
- Changing screens: not tested (one screen).

## Side checks

### Committing many layers off the main thread (`offmain/r1–r3.json`)

The System widget with two frame counters in groups far apart (bottom and top of the window), partitioned into 65
layers (21 groups, 44 tiles), sRGB window, redrawn and committed at 60 Hz from its skin thread for 3 s; a sampler
thread reads the window back as fast as it can (about 310–360 captures per second) and decodes both counters.

| | frames committed | distinct frames seen | captures where the two counters differ | longest one frame stayed |
|---|---|---|---|---|
| EP (E layers) | 180, 180, 180 | 180, 179, 179 | 0 of 1,030, 1,063, 1,023 | 21.0, 20.8, 24.7 ms |
| DP (IOSurfaces) | 180, 180, 180 | 180, 180, 180 | 0 of 968, 983, 937 | 20.7, 22.5, 20.4 ms |
| EP, main thread blocked 3 × 300 ms | 222 (53–54 during the blocks) | 222–223 (55–56 during the blocks) | 0 of 1,243–1,316 | 19.7–23.4 ms |
| DP, main thread blocked 3 × 300 ms | 222 (54 during the blocks) | 222 (54–56 during the blocks) | 0 of 1,176–1,223 | 19.6–24.3 ms |

Frames committed from the skin thread reach the screen (all but 0–1 of 180), keep reaching it while the main thread is
blocked, and every frame appears whole: no capture ever showed half of one commit and half of another. (A distinct
frame more than committed is the frame shown before the timer started; frames seen during a block include the ones
committed just before it.) The 1-minute load was 5.1–5.5 at the end of each round.

### Glass following a moving element through main-thread frames (`glass/r1–r3.json`, `glass/real-glass.json`)

An element moves 3 pt every frame at 60 Hz, so every frame is a main-thread frame as the plan has it: the skin thread
rasterizes, hands the main thread a patch (element frame and contents, glass frame) with an atomic state, waits at
most 50 ms, and on timeout reclaims the patch and commits the content itself; the main thread then only moves the
glass. The glass is a magenta stand-in view under ContentHost (exactly under the element), so any magenta in a
capture is glass the element has left. 4 s per scenario, 3 rounds (1-minute load 5.9–6.1 at the end of each).

| main thread | frames | applied by main / reclaimed by the skin | patch latency p50 / p99 / max | captures with glass visible beside the element |
|---|---|---|---|---|
| idle | 240 | 240 / 0 | 0.1 / 0.1–0.2 / 0.1–0.2 ms | 0 of 1,288–1,309 |
| blocked 30 ms every 250 ms | 224 | 224 / 0 | 0.1 / 26.0–26.7 / 29.0–30.6 ms | 0 of 1,313–1,327 |
| blocked 120 ms every 1 s | 216 | 209–211 / 5–7 (1–2 per block) | 0.1 / 0.2–49.1 / 49.8–50.7 ms | 81–92 of 1,285–1,297 (6.3–7.1 %), by at most 6 pt |

- The 50 ms bound holds: the skin thread never waited longer (the latest patch the main thread applied was 50.7 ms
  after it was posted, just after the timeout, when the skin thread lost the race for it), and it never waited at all
  while the main thread was idle.
- Blocks shorter than 50 ms: glass and element moved together in every capture.
- Longer blocks: after each timeout the element moves on alone and the glass stays where it was until the main thread
  runs again; it trailed by one or two frames' movement (3–6 pt) for part of each 120 ms block.
- With a real `NSGlassEffectView` (one round) the timing is the same (idle p99 1.6 ms, max 1.9 ms; 30 ms blocks: p99
  27.5, max 32.4 ms, 0 reclaims; 120 ms blocks: 6 reclaims, max 50.7 ms). Its tinted blur cannot be told apart from
  the background reliably in a capture, so drift was measured with the stand-in only.

### Refresh: swapping windows without a blank frame (`swap/r1–r3.json`)

A refresh as Deskset does it today replaces the window. The System widget (partition, sRGB window, skin thread) was
refreshed 25 times per variant while a sampler read back the window's area about 240 times per second, compositing only
those of our windows that the window server reported on screen, and classified each capture by the alpha at four points
of the panel: blank (no panel), doubled (two panels, more opaque than one), or normal.

⟪SWAP⟫

- No capture showed a blank or doubled window. The captures that straddled a swap (the window list changed between the
  check before and after the capture) are dropped, so a state shorter than one capture (about 4 ms, less than one
  display frame) cannot be ruled out by this method; nothing longer happened.
- Replacing the tree inside the same window needs no window-list change at all and takes 7 ms instead of 58 ms
  (a new window with a new layer tree and its first frame).
- An earlier version of this check composited the listed windows with `CGWindowListCreateImageFromArray`, which still
  includes a window 0.3 s after it was ordered out; it reported about 23 % "doubled" captures that were not on screen.

## Click-through on transparent pixels (needs a person at the Mac)

1. Run `scripts/spikes/layer-runtime/run.sh click` from Terminal. Two windows appear in the middle of the screen: a grey
   titled window "Click target (behind)" and, on top of it, a borderless skin window whose content is four layers
   committed from a skin thread.
2. Click once inside each numbered area of the skin window:
   - **1** top left, fully transparent (the grey window shows through) → expected: the terminal prints
     `click at (…) in the target window behind`.
   - **2** top middle, looks empty (alpha 1/255, like the glass hit fill) → expected: `… in the skin window`.
   - **3** blue square (opaque content) → expected: `… in the skin window`.
   - **4** dark translucent panel → expected: `… in the skin window`.
3. The program ends by itself after 90 s. Report the four printed lines; anything else (for example 1 landing in the
   skin window, or 2 falling through) means click-through by alpha does not work for layers committed off the main
   thread, and the plan's fallback (switching `ignoresMouseEvents` from the hit map) is needed.

## Not covered

- Question 8 (the `CARenderer` probe on the `macos-26` and `macos-26-intel` runners).
- A 1× external display, an sRGB display, and moving a window between screens (only the built-in XDR display here).
- WindowServer's memory from `footprint` or `vmmap`: both, and `proc_pid_rusage`, need root for WindowServer
  ("try running with `sudo`"), so it comes from `top` (MEM, 1 MB resolution), with WindowServer's resident size from
  `ps` and the GPU's memory in use from the I/O Registry as cross-checks.
- The real `NSGlassEffectView` in the glass check is only timed: its tint is not a flat color, so the read-back cannot
  tell whether it lags behind the element (the stand-in view can).
- Click-through (steps above).
