# H1: a skin as many Core Animation layers instead of one bitmap — results

Measured on 2026-09-27 and 2026-09-28 with the spike in this folder (`run.sh`, then `python3 summarize.py`). Every
number below comes from a JSON file next to this one; each section names its files. Questions 1–7 and the side checks
of the H1 experiment are answered here, and question 8 (a `CARenderer` probe on the CI runners, `../ci-probe/`,
measured on the runners on 2026-09-28) in its own section.

On 2026-09-27, while this experiment ran, Deskset itself stopped drawing skins with `draw(_:)` (called **A** below)
and started drawing each skin window on the main thread into a bitmap of its own, in the window's color space, that
becomes the view's layer contents, keeping pictures of meters that did not change (**B**). The plan's baseline is A;
this document measures against both and calls B "today". The second measurement campaign (2026-09-28) added B and
E layers in B's color space.

## Conditions

- MacBook Pro Mac16,8, Apple M4 Pro (14 cores), 24 GB; macOS 26.5.2 (25F84). `env.json`.
- One display: the built-in Liquid Retina XDR ("Built-in Retina Display", 1512 × 982 pt at 2×), color space
  **"Color LCD"** (the panel's own profile, Display P3 primaries: sRGB red is (0.9175, 0.2004, 0.1385) in it), 8 bits
  per sample, EDR headroom 16 (1 in use). No external and no sRGB display was attached, so the 1× rows, the "sRGB
  screen" rows and the screen-change part of question 7 are **not measured**.
- The Mac was not idle: other builds and self-test runs (one of them up to 6 cores), a browser, the iOS Simulator,
  desktop apps and the owner's own Deskset widgets ran at the same time, and WindowServer used 45–56 % of one core
  with none of the spike's windows on screen. Every CPU phase records the 1-minute load average at its start and end:
  3.4–12.5 (median 5.5) in the first campaign's cost runs, 4.1–21.0 (median 7.8) in the second's; 7 of 51 and 59 of
  99 cost runs, and 23 of 69 WindowServer CPU runs, had a phase above 8. **Numbers from runs with a load above 8 are
  marked provisional** (an asterisk in the tables, with how many of the rounds were affected). Memory and pixel results
  do not depend on the load.
- Memory: normal memory pressure (level 1) during every run used here, 1–2 GB free. (An earlier campaign ran under
  memory pressure level 2; its pixel, color and flip results were identical, its memory numbers are not used.)
- `phys_footprint` counts only pages that are mapped into the process. A `CGImage` made from a bitmap context keeps
  the context's pages by copy-on-write and is charged again only when something in the process reads it
  (`probes.json`: 8 such images of 9.77 MB each added 0.34 MB, and 78.75 MB once CoreGraphics drew them; a live
  9.77 MB context counted 9.78 MB). CA hands images to the window server without reading them (question 6). B's own
  bitmaps even leave the footprint: a design skin in B showed +1.86 MB for 8 s and then −0.1 MB; `vmmap` then listed
  its bitmap memory ("CG raster data") as a 2,000 KB copy-on-write region with 0 KB resident. So memory is also given
  as the uncompressed bytes of the bitmaps the layers or the view hold ("layer bitmaps", "own bitmaps").
- The spike logs the kind of context every draw gets. Describing a context with `CFCopyDescription` costs 2.76 µs
  and **leaks 214 bytes per call** on macOS 26.5 (`probes.json`: +20.39 MB per 100,000 calls; a color space's
  description leaks nothing), so the log describes each context type once and then only counts.
- Screen capture was allowed for the process running the spike (checked with `CGPreflightScreenCaptureAccess`, never
  requested). Only the spike's own windows are read back (`CGWindowListCreateImage` for one window,
  `CGWindowListCreateImageFromArray` for several). Since 2026-09-28 the windows open a few at a time at the bottom right
  of the screen.
- Dates: questions 1, 2 and 4 (`q1.json`, `q4-*.json`, `env.json`), the second cost campaign (`cost-b/`, `wscpu-b/`,
  `wsmem-b/`, `memtrace-b/`) are from 2026-09-28; questions 5–7, the first campaign (`cost/`, `wscpu/`, `wsmem/`,
  `memtrace/`), `probes.json` and the side checks are from 2026-09-27, run with the same code except where windows
  were placed on screen.

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
pixels, the base is the leading run of elements covering ≥ 50 % of the window (drawn once into a window-sized
bitmap), overlapping boxes are merged until stable, and the rest of the window is cut into row-band tiles that show
the base bitmap through `contentsRect` with nearest filtering. No element's ink escapes its box (checked for every
element at 5 ticks, `q5.json` → `inkEscapes`).

Ways a skin reaches the screen (`Runtime.swift`):

| name | what |
|---|---|
| **A** | Deskset until 2026-09-27: a flipped view draws the whole skin in `draw(_:)` on the main thread (a display-list context; Core Animation rasterizes it in this process on its accelerated path) |
| **B** | Deskset since 2026-09-27: the view draws the whole skin on the main thread into one of two bitmaps of its own (8-bit premultiplied BGRA **in the window's color space**) in `updateLayer` and sets it as the layer's contents |
| **B+kept** | B plus Deskset's kept pictures (`SkinBitmapDrawing`): runs of elements that did not change since the last frame are kept as whole-window pictures (at most 4) and copied; changed elements are drawn directly |
| **E1** | one layer; the skin thread calls `setNeedsDisplay` + `displayIfNeeded`, `draw(in:)` paints the whole skin |
| **EP** | the partition: base tiles plus one E layer per group (base pixels copied in with `.copy`, then the group's elements moved by whole pixels); the base bitmap is sRGB 8-bit |
| **EPw** | EP with the base bitmap in the window's color space (what B draws in) |
| **EPx / EPxw** | EP / EPw, but the dirty groups are drawn at their window position into one window-sized scratch bitmap (base restored under their boxes first; for EPxw in the window's color space) and each group layer copies its box out of it |
| **EP16** | EP in the default window with `RGBA16Float` layers and the base bitmap drawn in the window's space at 16-bit float (the combination closest to A, question 4) |
| **D1** | one layer whose `contents` is an sRGB, 8-bit, premultiplied IOSurface the skin thread draws into (pool of up to 3, skipping `isInUse`) |
| **DP / DPx** | the partition with IOSurface groups and an IOSurface base (DPx: through the scratch bitmap) |
| **C1 / CP / CPw / CPxw** | like D1 / DP, but each layer's `contents` is an image of one of two bitmaps of our own used in turn (8-bit premultiplied BGRA **in the window's color space**): what B does, per layer and from the skin thread. CPw: base bitmap in the window's space; CPxw: also through a scratch bitmap in that space |
| **OVE / OVD** | control: the panel in one layer and everything else in one layer on top (shares pixels), with E layers or our own bitmaps |

Layered modes use the plan's view structure: panel → flipped container → ContentHost (layer-backed, `isFlipped`,
`wantsUpdateLayer`, draws nothing) → `contentRoot` (created and owned by the runtime) → tiles and groups. Every layer
gets `contentsScale`, `contentsFormat = .RGBA8Uint` (unless stated), no actions; each skin commits from its own thread
(run loop, 8 MB stack) inside `CATransaction.begin/commit` followed by `flush`. The first `displayIfNeeded` happens in a
second transaction after the tree was committed (see question 4). "Default window" means `NSWindow.colorSpace` left
alone (the screen's; what Deskset does, in A and in B), "sRGB window" means `NSWindow.colorSpace = .sRGB` (the plan's
format for every layer).

Pixel comparisons: the window read back by the window server (8-bit BGRA in the display's color space, 520 × 392 px for
System), channel by channel; "max" is the largest channel difference in 8-bit levels, the percentage is the share of
pixels with any difference. Also composited over an opaque backdrop window (what a person sees over the desktop).
Two consecutive captures of every window were identical.

## Answers at a glance

| # | question | answer (details in the sections below) |
|---|---|---|
| 1 | partition vs one E layer vs A, read back from the screen (built-in XDR display, 2×, color space "Color LCD" ≈ Display P3) | **The partition equals one E layer when its base bitmap is in the E contexts' color space: max 1 in 7 px (0.003 %)**, all from CoreGraphics' whole-pixel translation of curved paths, and **0** when the groups are drawn through a window-sized scratch bitmap — in an sRGB window with an sRGB base, and in the default window with the base in the window's space. An sRGB base in the default window: max 1 in 48 %. **One E layer in the default window is identical to today's B**; E, B vs A: max 6 in 84 %. Rendering in an sRGB window changes today's B by max 9 in 54 % (A: max 10 in 87 %). Overlapping layers (reproduced): max 2–4 in 7–25 %. |
| 2 | E vs D | Identical (0) in an sRGB window; in the default window max 9 in 54 % (E follows the window's color space, D's surfaces are sRGB). Partition with IOSurfaces vs one IOSurface: max 1 in 7 px; through the scratch bitmap 0. Memory and CPU: question 3 (D costs more memory than E; C, our own bitmaps as `CGImage` contents, is in question 3 too). |
| 3 | memory and CPU at 2× | This process, per widget updating every second: the partition 2.17 MB (E) / 2.82 MB (C) / 3.49 MB (D) for a 260 × 196 pt System widget, 2.70 / 2.19 / 5.69 MB for the 360 pt design skin; one E layer 2.22 / 3.64 MB; today's B+kept 3.38 / 6.33 MB; A 15.5 / 123 MB (its accelerated path). WindowServer: at most +1.0 MB per widget in every way, no more than A or B (`top`; `footprint` and `vmmap` need root). CPU for 10 System widgets: **0.58–0.62 % when their updates run on one thread** (C / E partition; B+kept 0.75 %, A 0.62–0.78 %), but 1.24–1.51 % with one thread per widget updating at the same moment and 1.03 % spread over the second; WindowServer's CPU: no measurable change. Wakeups 1.4–4.6 per second for all 10 (13 when spread). 60 Hz visualizer: 298–300 of 300 frames on screen in every way; CPU C 4.07 %, D 4.18 %, E 5.57 %, B+kept 3.98 %, A 8.11 %. |
| 4 | the `draw(in:)` context and formats | A bitmap context (`kCGContextTypeBitmap`, data in this process) **in the window's color space** ("Color LCD" by default, sRGB in an sRGB window, Display P3 in a P3 window) — not always sRGB. 8 bpc for `RGBA8Uint`, 16 bpc float for `RGBA16Float` (extended sRGB in an sRGB window), `kCGContextTypeCoreAnimationAutomatic` when no format is set; A gets a display list. **Closest to today's B: `RGBA8Uint` in the default (or a P3) window: identical.** Closest to A: `RGBA16Float` in the default window: identical. The plan's `RGBA8Uint` in an sRGB window: max 9 in 54 % from B, max 10 in 87 % from A, identical to D. |
| 5 | gradients cut at box edges (pure CG) | 270° StylePanel gradient cut by a 100 × 30 pt box: max 1 in 70.8 % of the box; **64.4 % reproduced exactly** (298 box positions on a 1 pt grid); over all positions median 67.9 %, 0–84 %. Box at the panel's top left, translation only, solid translucent panel: 0. **Whole-window base bitmap + whole-pixel sub-rectangles: 0.** |
| 6 | base tiles sharing one image | **Counted once**: 61 tiles cost what one layer with the image costs (this process within 0.08 MB; WindowServer +12–13 MB either way; in the default window CA's color-converted copy, +19.6 MB, is made once for all 61 tiles, but once per image for separate copies: 8 copies +156.6 MB). **Read back byte for byte**: 0 differing pixels offscreen (`CARenderer`) and on screen (vs one layer). |
| 7 | ContentHost flipping | All markers in place in 5 of 5 captures over 4 resizes; **AppKit wrote to `contentRoot` 0 times** (25 times to a layer-hosting root). Screen change not tested (one screen). |
| 8 | offscreen `CARenderer` on the CI runners | **Both runners have a Metal device** ("Apple Paravirtual device" on `macos-26` and on `macos-26-intel`) and render every tree; **within a run, tiles vs one layer and E groups vs one layer are identical (0) on both.** Against this Mac: `macos-26` is byte-identical for bitmaps and flat colors (Core Animation's own shapes: max 1 in 0.2–0.65 %); `macos-26-intel` differs everywhere except copied bitmaps (CoreGraphics output depends on the CPU architecture: identical to this Mac's x86_64 build under Rosetta). Two silent traps: `CARenderer` does not clear the texture, and on the Intel runner a shared texture never sees the GPU's writes (the first run compared garbage with garbage and called it identical). Per render at 2× (a new 20-layer tree each time, one renderer): 3.4 ms on `macos-26`, 7.0 ms on `macos-26-intel`, 0.5 ms here. |
| – | layers committed off the main thread | 65 layers at 60 Hz from a skin thread: 179–180 of 180 frames reached the screen, 0 of 13,428 captures (12 runs) showed two commits mixed, and frames kept reaching the screen while the main thread was blocked (53–54 committed, 54–56 distinct frames seen during 3 × 300 ms blocks). |
| – | glass following a moving element | Every frame a main-thread frame at 60 Hz: **the 50 ms bound holds** (no patch waited longer than 50.7 ms; with 120 ms main-thread stalls 5–7 of 216 frames per run were reclaimed). No drift while stalls stay under 50 ms (0 of about 1,300 captures per run); 120 ms stalls leave the glass up to 6 pt (two frames' movement) behind the element in 6.3–7.1 % of the captures. |
| – | refresh by swapping windows | **No blank and no doubled frame** in 300 swaps (4 ways, 3 rounds, about 240 captures per second); a new window with its first frame takes 58 ms, replacing `contentRoot`'s layers in the same window 7 ms. |
| – | click-through on transparent pixels | Needs a person: steps near the end. |

## What this means for the plan's choice (stop point 0)

The plan's table picks E or D from four outcomes. What H1 found for each:

| the plan's condition | found | so |
|---|---|---|
| E's context is sRGB 8-bit on sRGB and P3 / XDR screens | No: it is in the **window's** color space (the screen's "Color LCD" by default; sRGB only in an sRGB window). No sRGB screen was available. | The runtime decides it by setting (or not setting) the window's color space. |
| E's context follows the screen, so copying base sub-rectangles converts colors (→ D) | Only when the base bitmap and the E contexts are in different spaces (max 1 in 48 %). With the base drawn in the window's space: 7 px of translation noise; through a scratch bitmap in that space: 0. | **D is not needed for exact colors.** (D is exact too, but only in an sRGB window.) |
| memory beyond the plan's targets (→ D with pooling) | D uses the most memory of the layered ways (IOSurfaces charged in full): 3.49 MB per System widget, 5.69 MB for the design skin (over its 4.95 MB limit). | D does not help memory. |
| the partition still differs from one layer on screen | By 1 level in 7 px (0.003 %) from moving curved paths by whole pixels: within G2's tolerance (≤ 2, ≤ 0.1 %), not the hoped-for 0. 0 with a scratch bitmap, which costs one more window bitmap (+1.2–2.6 MB) and +0.3–0.5 % CPU for 10 widgets. | Use the partition; decide whether G2 expects 0 (scratch bitmap) or accepts the 7 px. |

**Recommendation: E, not D; keep the window's own color space; batch the skins' updates.**

1. **E, as the threading plan already chose; C is a measured alternative.** C (our own bitmaps, two per group used in
   turn, whose images become the contents: what B does, per group and from the skin thread) shows exactly E's pixels
   (C1 = E1 = B; CPw = EPw) and gives the runtime the control over buffers the plan wanted from D, without
   IOSurfaces. It was cheaper than E at 60 Hz (4.07 vs 5.57 %) and with ten threads updating together (1.24 vs
   1.51 %), equal on one thread (0.58 vs 0.62 %) and for the design skin (0.09 vs 0.12 %), and it needs a little more
   memory for skins with many groups (System widget 2.82 vs 2.17 MB; design 2.19 vs 2.70 MB). D (sRGB IOSurfaces)
   had similar CPU (1.13 %, 4.18 %) but the most memory.
2. **Color space: leave the window's color space alone and draw the base (and scratch) bitmap in it**, as B does
   today. Then the partition shows exactly what Deskset shows today (EPxw / CPxw = B: 0 differing pixels; without the
   scratch bitmap 7 px). The plan's alternative, an sRGB window, makes E equal to D and to the sRGB offline
   references, but changes today's look by up to 9 levels in 54 % of the pixels on this display (and differs from A
   by up to 10 in 87 %), not "±2 in about half" as the plan assumed from the review. The cost of the window's space:
   the base bitmap and every group are drawn again when a window moves to a screen with another color space (B already
   does this), and the offline references (`--render`, `CARenderer`) must be rendered in the same space to compare
   byte for byte.
3. **CPU depends more on how the skins' updates are scheduled than on layers vs one bitmap.** The plan wants 10 widgets
   updating every second under 1 % of a core. The partition meets it when the updates run one after another on one
   thread (EPw 0.62 %, CPw 0.58 %; today's B+kept 0.75 %), not with one thread per widget (updates at the same
   moment: 1.24–1.51 %; spread over the second: 1.03 %, and 13 wakeups per second). The threading plan's one thread
   per skin should be measured for this in the real engine before building on it (for example, a shared pool of skin
   threads, or coalescing updates that fall due together).
4. **Memory, WindowServer, opening, 60 Hz**: the partition meets the design-skin limit (2.2–2.7 MB against 4.95), is
   at the 2 MB limit for a System-sized widget (1.9–2.8 MB; that limit is for idle widgets, these updated every
   second), adds no WindowServer memory beyond A or B (+0.1–0.6 MB per widget) and no measurable WindowServer CPU for
   10 widgets, opens 10 widgets in 55–86 ms and delivers 299–300 of 300 frames at 60 Hz.
5. **What the layer runtime buys over today's B+kept**: drawing and committing on the skin thread (frames arrive
   while the main thread is blocked; the glass patch's 50 ms bound holds), glass and native views in the same tree,
   and less memory than B+kept's whole-window pictures (design: 2.2–2.7 MB vs 6.3 MB). With batched updates its CPU
   is at B+kept's level or below; with one thread per widget it is not.
6. **CI (question 8)**: the offscreen pixel gate can run on both runners, comparing two trees rendered in the same run
   (never pixels from another machine), provided the renderer clears the texture before every render, reads back
   through a managed texture where the GPU has no unified memory, and refuses to pass when a canary image does not
   come back byte for byte. Its `CARenderer` time is about a minute per runner.

## 1. Partitioned layers vs one E layer vs A and B on screen (`q1.json`, crops in `crops/`)

System widget, tick 7 (19 groups, 38 base tiles), each mode in its own window, four windows at a time.

| comparison | default window (the screen's color space, like A and B) | sRGB window |
|---|---|---|
| EP (partition, sRGB base bitmap) vs E1 (one E layer) | max 1, 48.18 % (98,207 px) | **max 1, 0.003 % (7 px)** |
| **EPw** (partition, base in the window's space) vs E1 | **max 1, 0.003 % (7 px)** | – |
| EPx (through an sRGB scratch bitmap) vs E1 | max 9, 56.58 % | **0** |
| **EPxw** (base and scratch bitmap in the window's space) vs E1 | **0** | – |
| E1 vs **B** (today) | **0** | max 9, 53.81 % (E1 in an sRGB window vs B in the default window) |
| EPw vs B / EPxw vs B | max 1, 7 px / **0** | – |
| C1 / CPw / CPxw (our own bitmaps as contents) vs B | **0** / max 1, 7 px / **0** | C1 / CP vs E1: 0 / max 1, 7 px |
| B vs A | max 6, 84.32 % | 0 (B and A both in an sRGB window) |
| E1 vs A | max 6, 84.32 % | 0 (in an sRGB window); vs A in the default window: max 10, 87.24 % |
| A in an sRGB window vs A in the default window | – | max 10, 87.24 % |
| OVE (overlapping E layers) vs E1 | max 2, 6.80 % (inside group boxes 11.28 %) | max 3, 12.15 % (20.15 %) |
| OVD (overlapping own bitmaps) vs D1 | max 4, 24.94 % (31.88 %) | max 3, 12.15 % (20.15 %) |

- **The partition can equal one E layer and today's B pixel for pixel.** In the default window, an E layer's context is
  in the window's color space (question 4), exactly like B's own bitmap: E1 and B are identical. A partition whose
  base bitmap is drawn in the same space differs from both by 1 level in 7 pixels (0.003 %, all inside group boxes);
  drawing the groups through a window-sized scratch bitmap in that space (EPxw) gives **0 differing pixels**, also over
  the backdrop. In an sRGB window the same holds with an sRGB base (EP: 7 px; EPx: 0).
- The 7 pixels come from CoreGraphics itself: drawing the same curved path moved by whole device pixels does not give
  identical pixels (question 5). The scratch bitmap draws every element at its window position, so nothing moves.
- **Mixing color spaces costs 48 % of the pixels**: an sRGB base bitmap copied into E contexts that are in the
  display's space is converted by CoreGraphics while the base tiles are converted by the window server; the two
  conversions round differently (max 1 in 48 % of the pixels, over the backdrop max 2 in 48.11 %). EPx in the default
  window is worse (max 9, 56.58 %): its sRGB scratch bitmap carries sRGB pixels into contexts in the display space.
- **What an sRGB window changes against today**: anything rendered in 8-bit sRGB (E1, EP, D1 or B in an sRGB window)
  differs from today's B by up to 9 levels in 53.81 % of the pixels (106,883 by 1, 2,705 by 2, 50 by 3, 44 by 4–7,
  2 by 8–9); outside the group boxes (the panel alone) at most 1; over the backdrop max 9 in 65.04 %.
- **A vs B and E**: A is rendered in the window's color space at a higher precision than an 8-bit bitmap (question 4:
  an `RGBA16Float` E layer equals A exactly), so B and E1 differ from A by up to 6 levels in 84 % of the pixels
  (167,947 by 1, 3,896 by 2, 40 by 3–6; the panel alone at most 2). 8-bit sRGB differs from A by up to 10 in 87 %.
  In an sRGB window A, B, E1 and D1 are identical.
- The window server's color matching differs from CoreGraphics' by 1 level: every mode rendered in sRGB differs from
  the offline sRGB reference converted by CoreGraphics into the display space by max 1 in 14.91 % of the pixels.
- **Overlapping layers** (reproduced): putting the panel and the content in two layers that share pixels changes up to
  2–4 levels in 7–25 % of the pixels, inside the content's boxes 11–32 %; the partition does not share pixels and has
  none of this.
- Crops (top left of the System widget, 200 × 76 px): `q1-A.png`, `q1-E1-srgb.png`, and difference maps (red =
  different) `q1-diff-B-vs-A.png`, `q1-diff-E1-vs-A.png`, `q1-diff-E1-srgb-vs-A.png`, `q1-diff-E1-srgb-vs-B.png`,
  `q1-diff-EP-vs-E1.png` (default window), `q1-diff-OVD-srgb-vs-D1-srgb.png`.

## 2. E vs D (`q1.json`; memory and CPU in question 3)

| comparison | default window | sRGB window |
|---|---|---|
| D1 vs E1 | max 9, 53.81 % | **0** |
| D1 vs B (today) | max 9, 53.81 % | max 9, 53.81 % |
| DP (IOSurface base) vs D1 | max 1, 0.003 % (7 px) | max 1, 0.003 % (7 px) |
| DPx vs D1 | **0** | **0** |
| DP with a CGImage base vs D1 | max 1, 5.71 % (base tiles: 14.39 % of their pixels) | – |
| C1 vs E1 / CPw vs EPw (C: images of our own bitmaps in the window's space) | **0** / **0** | C1 vs E1: **0** |
| D1 vs A | max 10, 87.24 % | max 10, 87.24 % (vs A in the default window) |

D's pixels do not depend on the window's color space (D1 is identical in both windows): the IOSurfaces are sRGB and
the window server converts them. E matches D exactly once the window is sRGB, and matches B exactly in the default
window. A base given as a CGImage instead of an IOSurface is converted differently from the same pixels in an
IOSurface (max 1 in 14 % of the tile pixels). (D with IOSurfaces tagged with the display's color space, which should
match B like E does, was not measured.)

## 3. Memory and CPU at 2× (`cost/`, `cost-b/`, `wscpu/`, `wscpu-b/`, `wsmem/`, `wsmem-b/`, `memtrace/`, `memtrace-b/`, `summary.json`)

**How** (`CostRun.swift`). Every run is a fresh process that opens one scenario in one mode: **ten** = 10 System
widgets (19 groups each; 12 groups change every second, `Update=1000`), **design** = one 360 pt design skin (8 groups,
2 change every second), **sixty** = one visualizer at 60 Hz (34 groups, 33 change every frame). Each widget has its own
skin thread (A and B: the main thread).

- This process: `phys_footprint` (task_info, median of 3 samples) before opening and after 20 s of updates (CA adds
  second buffers to layers that keep updating within 5–20 s, `memtrace/`), divided by the number of widgets. Next to
  it, the uncompressed bytes of the bitmaps the widget's layers hold ("layer bitmaps": backing stores, contents images
  and surfaces) and of the bitmaps the runtime or view keeps itself ("own bitmaps": base, scratch, IOSurface pools,
  B's two bitmaps and kept pictures). One bitmap of the window: 0.78 MB (System, 520 × 392 px), 1.98 MB (design),
  0.48 MB (visualizer).
- CPU: 3 pairs of 5 s phases, "on" (updating) and "off" (timers stopped, windows ordered out); this process from
  `getrusage` (% of one core, on phases), wakeups from `proc_pid_rusage` (interrupt wakeups per second, this
  process, all widgets). WindowServer's CPU from `ps` (10 ms resolution); because it moves by several % of a core on
  this busy screen, it was measured again separately (`wscpu`): 10 pairs of 2 s phases per run, windows kept on screen
  in the off phases (only their updates stop), an opaque backdrop window of ours under them; the increase per pair,
  median and mean ± standard error over 30 pairs.
- WindowServer's memory: `footprint`, `vmmap` and `proc_pid_rusage` all need root for WindowServer ("try running with
  `sudo`"; `sudo` needs a password here), so its footprint comes from `top` (MEM, 1 MB resolution). It also jumps by
  tens of MB on its own on a busy screen, so it is measured on its own (`wsmem`): one opening per fresh process, the
  step between the median of 5 `top` samples before opening and after 8 s of updates; a round counts as clean when the
  footprint went back to its start after closing (within 2 MB). With it: WindowServer's resident size (`ps`) and the
  GPU's "In use system memory" (the whole system, from the I/O Registry).
- Frame cost: time to draw one update (A: recording in `draw(_:)`; B: drawing the bitmap in `updateLayer`; E / D:
  drawing before the commit, on the skin thread) and to commit it.
- Rounds: every combination 3 times (the cost and wscpu tables; combinations interleaved, round 1 of each, then
  round 2…), WindowServer memory 5 times. Tables give the median and (min–max).

Two campaigns: **2026-09-27** (E and D in sRGB windows, the plan's format, and A) and **2026-09-28** (today's B and
B+kept, E and C in the window's own color space, A again as the bridge; 10 System widgets also on one shared skin
thread and with their updates spread over the second). In the tables, `*` marks a CPU number from rounds with a
1-minute load above 8 (provisional; the last column says how many rounds).

**ten: 10 System widgets, Update=1000 (per widget; CPU and wakeups for all 10)**

| campaign | mode | process MB (phys_footprint increase) | layer / own bitmaps MB | process CPU % of one core | interrupt wakeups/s | frame cost p50 µs (draw / commit) | open ms | load max |
|---|---|---|---|---|---|---|---|---|
| 09-27 | A | 15.33 (15.30–15.48) | 0.00 / 0.00 | 0.78 (0.62–0.82)* | 5.7 (5.2–5.7) | 205 (202–206) / – | 12 (11–21) | 10.73 (1 of 3) |
| 09-27 | E1, sRGB window | 2.22 (2.16–2.24) | 1.55 / 0.00 | 2.04 (1.99–2.94)* | 3.4 (3.4–3.8) | 2113 (2059–2224) / 102 (53–143) | 54 (48–54) | 12.48 (1 of 3) |
| 09-27 | EP, sRGB | 2.16 (2.16–2.21) | 1.58 / 0.78 | 1.45 (1.40–1.46) | 3.6 (3.5–3.7) | 1456 (1431–1463) / 351 (345–363) | 57 (50–58) | 6.77 |
| 09-27 | EPx, sRGB | 3.44 (3.41–3.44) | 1.58 / 1.55 | 1.91 (1.68–2.26) | 3.5 (3.4–3.7) | 1956 (1930–2020) / 263 (227–323) | 58 (58–62) | 6.88 |
| 09-27 | EP16 (default window, 16-bit) | 3.58 (3.54–3.61) | 3.16 / 1.55 | 1.39 (1.33–1.59)* | 6.5 (6.2–6.8) | 1285 (1237–1330) / 458 (450–465) | 66 (62–80) | 10.71 (2 of 3) |
| 09-27 | D1, sRGB | 2.35 (2.28–2.37) | 0.83 / 1.66 | 1.98 (1.98–2.03) | 1.4 (1.4–1.4) | 2058 (2042–2094) / 104 (92–169) | 52 (50–56) | 7.55 |
| 09-27 | DP, sRGB | 3.49 (3.48–3.51) | 1.56 / 2.89 | 1.13 (1.11–1.28) | 1.4 (1.4–1.5) | 1273 (1210–1367) / 539 (508–552) | 77 (70–79) | 6.37 |
| 09-28 | A | 15.52 (15.34–15.73) | 0.00 / 0.00 | 0.62 (0.62–0.64)* | 6.8 (5.9–7.2) | 190 (175–191) / – | 31 (24–32) | 8.48 (2 of 3) |
| 09-28 | **B** (today, drawn in full) | 0.24 (0.24–0.28) | 0.78 / 1.55 | 1.56 (1.39–1.57)* | 1.8 (1.4–2.1) | 1384 (1283–1488) / – | 21 (19–29) | 19 (2 of 3) |
| 09-28 | **B+kept** (today, as Deskset) | 3.38 (3.37–3.38) | 0.78 / 4.67 | 0.75 (0.65–0.82)* | 1.6 (1.6–1.9) | 637 (594–682) / – | 24 (14–31) | 10.6 (3 of 3) |
| 09-28 | E1, default window | 2.22 (1.96–2.29) | 1.55 / 0.00 | 2.07 (2.05–2.16)* | 3.5 (3.4–3.7) | 2023 (1981–2524) / 157 (98–180) | 46 (45–53) | 10.4 (2 of 3) |
| 09-28 | EPw, default window | 2.17 (2.15–2.19) | 1.58 (1.52–1.58) / 0.78 | 1.51 (1.44–1.53)* | 3.7 (3.5–3.9) | 1481 (1415–1560) / 386 (328–424) | 68 (61–83) | 8.48 (1 of 3) |
| 09-28 | EPxw, default window | 3.44 (3.37–3.47) | 1.54 (1.50–1.58) / 1.55 | 1.81 (1.76–2.06)* | 3.9 (3.7–4.0) | 2106 (1914–2116) / 284 (234–297) | 60 (59–75) | 13.61 (1 of 3) |
| 09-28 | C1, default window | 0.88 (0.84–0.88) | 0.78 / 1.55 | 2.08 (2.06–2.09)* | 1.4 (1.4–1.7) | 2014 (1998–2026) / 228 (216–233) | 54 (45–74) | 8.64 (1 of 3) |
| 09-28 | CPw, default window | 2.82 (2.81–2.83) | 1.25 / 1.73 | 1.24 (1.21–1.25)* | 1.4 | 1166 (1155–1188) / 457 (427–497) | 60 (58–84) | 11.01 (1 of 3) |
| 09-28 | CPxw, default window | 4.04 (4.02–4.07) | 1.25 / 2.51 | 1.72 (1.68–1.77)* | 1.5 (1.4–1.5) | 1752 (1727–1918) / 347 (319–370) | 74 (59–89) | 9.69 (2 of 3) |
| 09-28 | E1, 10 widgets on one skin thread | 1.70 (1.68–1.73) | 1.55 / 0.00 | 1.41 (1.37–1.43)* | 4.6 (4.0–5.4) | 1235 (1228–1275) / 22 | 50 (46–51) | 9.42 (1 of 3) |
| 09-28 | C1, 10 widgets on one skin thread | 0.20 (0.20–0.24) | 0.78 / 1.55 | 1.50 (1.37–1.50)* | 1.4 (1.4–1.4) | 1279 (1252–1361) / 31 (30–33) | 47 (44–48) | 11.92 (1 of 3) |
| 09-28 | EPw, 10 widgets on one skin thread | 1.89 (1.88–1.89) | 1.58 / 0.78 | 0.62 (0.61–0.62)* | 3.4 (3.0–3.7) | 447 (446–451) / 51 (50–53) | 55 (55–56) | 16.82 (1 of 3) |
| 09-28 | CPw, 10 widgets on one skin thread | 2.46 (2.42–2.46) | 1.25 / 1.73 | 0.58 (0.58–0.61)* | 1.4 (1.4–1.5) | 453 (437–474) / 62 (60–67) | 86 (70–102) | 11.89 (2 of 3) |
| 09-28 | E1, 10 threads, updates spread over the second | 1.42 (1.38–1.50) | 1.55 / 0.00 | 1.85 (1.79–1.85)* | 12.5 (11.7–13.8) | 1574 (1536–1582) / 41 (40–44) | 52 (45–55) | 9.47 (1 of 3) |
| 09-28 | EPw, 10 threads, updates spread over the second | 1.77 (1.75–1.80) | 1.58 / 0.78 | 1.03 (1.01–1.05)* | 13.3 (13.0–13.3) | 700 (688–712) / 88 (86–90) | 66 (55–77) | 10.72 (2 of 3) |

**design: one 360 pt design skin, Update=1000**

| campaign | mode | process MB (phys_footprint increase) | layer / own bitmaps MB | process CPU % of one core | interrupt wakeups/s | frame cost p50 µs (draw / commit) | open ms | load max |
|---|---|---|---|---|---|---|---|---|
| 09-27 | A | 123.45 (119.83–123.75) | 0.00 / 0.00 | 0.20 (0.17–0.25)* | 3.9 (3.7–3.9) | 303 (271–363) / – | 2 (2–3) | 8.69 (1 of 3) |
| 09-27 | E1, sRGB window | 4.36 (3.91–4.97) | 3.96 / 0.00 | 0.33 (0.33–0.39) | 3.5 (3.2–3.6) | 2640 (2621–2893) / 25 (23–25) | 9 (7–10) | 6.37 |
| 09-27 | EP, sRGB | 2.81 (2.36–2.95) | 3.11 / 1.98 | 0.12 (0.11–0.14) | 3.8 (3.5–3.8) | 406 (405–410) / 26 (24–27) | 7 (6–7) | 6.26 |
| 09-27 | D1, sRGB | 4.42 (3.25–4.97) | 2.03 / 4.06 | 0.31 (0.31–0.34) | 1.4 (1.4–1.4) | 2698 (2677–2785) / 35 (33–39) | 7 (7–7) | 6.17 |
| 09-27 | DP, sRGB | 5.69 (5.42–5.91) | 3.02 / 5.40 | 0.09 (0.09–0.09) | 1.4 | 397 (397–421) / 49 (40–51) | 7 (6–9) | 7.32 |
| 09-28 | A | 122.94 (122.52–123.22) | 0.00 / 0.00 | 0.15 (0.15–0.17)* | 4.4 (4.4–4.9) | 260 (238–268) / – | 3 (2–7) | 10.54 (3 of 3) |
| 09-28 | **B** (today, drawn in full) | 0.52 (-0.25–1.09) | 1.98 / 3.96 | 0.34 (0.32–0.34)* | 1.5 (1.4–1.6) | 2768 (2691–2960) / – | 7 (4–7) | 20.96 (2 of 3) |
| 09-28 | **B+kept** (today, as Deskset) | 6.33 (5.23–6.47) | 1.98 / 9.89 | 0.14 (0.14–0.16)* | 1.4 (1.4–1.6) | 849 (793–948) / – | 6 (4–6) | 13.35 (2 of 3) |
| 09-28 | E1, default window | 3.64 (3.14–4.41) | 3.96 / 0.00 | 0.35 (0.34–0.36)* | 3.2 (2.9–3.4) | 2775 (2670–2919) / 30 (22–33) | 11 (11–11) | 13.05 (2 of 3) |
| 09-28 | EPw, default window | 2.70 (2.28–3.03) | 3.11 / 1.98 | 0.12 (0.12–0.14)* | 3.4 (3.3–3.5) | 449 (404–464) / 32 (26–37) | 9 (8–15) | 10.3 (2 of 3) |
| 09-28 | EPxw, default window | 5.27 (5.11–5.36) | 3.11 / 3.96 | 0.15 (0.14–0.16)* | 3.5 (3.5–3.5) | 774 (713–811) / 30 (25–32) | 8 (8–11) | 10.7 (2 of 3) |
| 09-28 | C1, default window | 0.25 (-0.19–0.78) | 1.98 / 3.96 | 0.33 (0.32–0.33)* | 1.5 (1.4–1.6) | 2895 (2800–2932) / 47 (46–48) | 7 (5–12) | 10.12 (1 of 3) |
| 09-28 | CPw, default window | 2.19 (1.53–2.55) | 2.87 / 3.77 | 0.09 (0.09–0.10)* | 1.4 (1.4–1.4) | 445 (444–448) / 56 (56–58) | 9 (9–12) | 13.86 (2 of 3) |
| 09-28 | CPxw, default window | 4.50 (3.97–5.02) | 2.87 / 5.75 | 0.12 (0.12–0.13)* | 1.4 (1.3–1.5) | 718 (714–823) / 56 (50–61) | 12 (9–16) | 10.42 (3 of 3) |

**sixty: one visualizer at 60 Hz**

| campaign | mode | process MB (phys_footprint increase) | layer / own bitmaps MB | process CPU % of one core | interrupt wakeups/s | frame cost p50 µs (draw / commit) | open ms | load max |
|---|---|---|---|---|---|---|---|---|
| 09-27 | A | 3.17 (2.53–3.75) | 2.86 / 0.00 | 7.24 (7.13–7.33) | 233.2 (178.2–266.0) | 149 (143–152) / – | 5 (4–6) | 6.59 |
| 09-27 | E1, sRGB window | 1.58 (1.30–1.83) | 1.43 (0.95–1.43) / 0.00 | 6.20 (6.06–6.24)* | 62.4 (62.3–62.5) | 958 (934–965) / 20 (18–22) | 7 (4–8) | 8.86 (1 of 3) |
| 09-27 | EP, sRGB | 1.12 (1.08–1.22) | 0.77 / 0.48 | 5.20 (4.73–5.59)* | 60.4 (60.1–60.4) | 590 (560–598) / 175 (162–188) | 6 (5–6) | 9.45 (1 of 3) |
| 09-27 | D1, sRGB | 1.25 (1.22–1.34) | 0.50 / 1.00 | 6.34 (6.26–6.69) | 60.2 (60.1–60.3) | 955 (946–999) / 32 (30–33) | 4 (3–8) | 6.92 |
| 09-27 | DP, sRGB | 2.56 (2.53–3.05) | 1.06 / 2.05 (2.05–2.57) | 4.18 (4.06–4.33) | 60.3 (60.0–60.3) | 454 (454–487) / 167 (163–169) | 12 (10–12) | 7.98 |
| 09-28 | A | 3.02 (2.98–3.23) | 1.90 (1.90–2.86) / 0.00 | 8.11 (7.95–8.86)* | 336.2 (303.2–401.4) | 150 (140–150) / – | 6 (3–7) | 9.26 (3 of 3) |
| 09-28 | **B** (today, drawn in full) | 1.00 (0.94–1.00) | 0.48 / 0.95 | 7.73 (7.51–7.93)* | 67.9 (67.9–72.7) | 1066 (1041–1075) / – | 8 (2–8) | 20.32 (3 of 3) |
| 09-28 | **B+kept** (today, as Deskset) | 0.95 (0.86–1.62) | 0.48 / 1.43 | 3.98 (3.90–4.08) | 79.6 (74.1–85.8) | 431 (428–442) / – | 6 (6–7) | 7.82 |
| 09-28 | E1, default window | 1.12 (1.03–1.42) | 1.43 / 0.00 | 6.49 (6.41–6.50)* | 62.3 (62.1–62.5) | 991 (988–999) / 21 (18–23) | 6 (6–12) | 11.12 (3 of 3) |
| 09-28 | EPw, default window | 1.14 (1.12–1.31) | 0.77 / 0.48 | 5.57 (5.28–5.57)* | 60.3 (60.2–60.5) | 636 (631–637) / 189 (177–191) | 8 (8–10) | 9.7 (3 of 3) |
| 09-28 | EPxw, default window | 1.77 (1.77–1.97) | 0.77 / 0.95 | 6.37 (6.10–6.51)* | 61.6 (60.3–67.5) | 775 (765–810) / 177 (173–181) | 11 (5–14) | 8.11 (1 of 3) |
| 09-28 | C1, default window | 0.58 (0.30–0.81) | 0.48 / 0.95 | 7.08 (7.04–7.17)* | 60.2 (60.1–60.3) | 1083 (1064–1084) / 43 (42–48) | 7 (7–8) | 13.27 (2 of 3) |
| 09-28 | CPw, default window | 1.78 (1.78–1.81) | 0.77 / 1.06 | 4.07 (4.04–4.12)* | 60.2 (60.2–60.3) | 482 (477–484) / 134 (133–136) | 11 (9–12) | 9.9 (1 of 3) |
| 09-28 | CPxw, default window | 2.53 (2.42–2.64) | 0.77 / 1.53 | 4.95 (4.83–4.99)* | 60.3 (60.1–60.9) | 642 (630–645) / 122 (120–124) | 7 (5–10) | 9.39 (1 of 3) |

**WindowServer CPU** (wscpu: increase per on / off pair, % of one core)

| campaign | combination | median (min–max) of 30 pairs | mean ± SE | process CPU % | load max |
|---|---|---|---|---|---|
| 09-27 | sixty, A | -1.58 (-18.46–1.37) | -4.324 ± 1.024* | 7.51 (6.97–7.91) | 8.09 (1 of 3) |
| 09-27 | sixty, D1, sRGB | 0.51 (-5.75–5.20) | 0.094 ± 0.335* | 7.22 (6.39–11.29) | 8.83 (2 of 3) |
| 09-27 | sixty, DP, sRGB | 1.98 (-2.71–6.31) | 2.128 ± 0.306* | 5.22 (4.13–7.24) | 12.18 (1 of 3) |
| 09-27 | sixty, E1, sRGB window | -0.47 (-2.71–3.64) | -0.349 ± 0.263* | 6.42 (6.38–7.73) | 11.88 (1 of 3) |
| 09-27 | sixty, EP, sRGB | 1.49 (-0.47–6.24) | 1.742 ± 0.291* | 5.10 (5.03–5.72) | 14.03 (2 of 3) |
| 09-27 | ten, A | -0.01 (-2.46–1.94) | -0.221 ± 0.206* | 0.71 (0.69–0.75) | 10.07 (2 of 3) |
| 09-27 | ten, D1, sRGB | -0.42 (-3.38–4.38) | -0.241 ± 0.335* | 1.99 (1.99–3.20) | 27 (1 of 3) |
| 09-27 | ten, DP, sRGB | 0.01 (-1.94–1.95) | 0.078 ± 0.194* | 1.15 (1.12–1.29) | 13.49 (2 of 3) |
| 09-27 | ten, E1, sRGB window | -0.02 (-2.47–2.40) | -0.103 ± 0.243 | 2.39 (1.95–2.42) | 6.33 |
| 09-27 | ten, EP, sRGB | -0.01 (-2.93–1.95) | -0.115 ± 0.225* | 1.45 (1.40–2.21) | 20.38 (1 of 3) |
| 09-28 | sixty, A | -2.17 (-22.87–1.34) | -5.297 ± 1.388 | 7.32 (6.69–7.35) | 6.82 |
| 09-28 | sixty, **B** (today, drawn in full) | -0.79 (-21.24–1.55) | -5.469 ± 1.551 | 7.96 (7.58–8.67) | 7.55 |
| 09-28 | sixty, **B+kept** (today, as Deskset) | -1.89 (-19.79–6.02) | -4.052 ± 1.316 | 4.46 (4.09–4.58) | 6.73 |
| 09-28 | sixty, C1, default window | 0.51 (-8.72–3.93) | 0.212 ± 0.425* | 7.03 (6.85–7.08) | 10.25 (1 of 3) |
| 09-28 | sixty, CPw, default window | 1.22 (-7.80–7.27) | 1.074 ± 0.542* | 3.88 (3.75–4.07) | 8.71 (1 of 3) |
| 09-28 | sixty, E1, default window | -0.21 (-3.94–4.39) | -0.384 ± 0.332* | 6.43 (6.31–6.52) | 13 (1 of 3) |
| 09-28 | sixty, EPw, default window | -0.99 (-2.93–0.97) | -0.972 ± 0.231* | 5.27 (5.18–5.36) | 8.68 (1 of 3) |
| 09-28 | ten, A | 0.01 (-4.41–5.29) | 0.022 ± 0.318* | 0.69 (0.69–0.82) | 9.03 (1 of 3) |
| 09-28 | ten, **B** (today, drawn in full) | 0.01 (-2.91–5.76) | 0.233 ± 0.316* | 1.38 (1.35–1.53) | 18.19 (1 of 3) |
| 09-28 | ten, **B+kept** (today, as Deskset) | 0.10 (-5.37–4.88) | 0.217 ± 0.459* | 0.63 (0.61–0.65) | 14.49 (1 of 3) |
| 09-28 | ten, CPw, default window | -0.26 (-4.83–1.95) | -0.357 ± 0.272* | 1.17 (1.16–1.17) | 9.79 (2 of 3) |
| 09-28 | ten, E1, default window | -0.20 (-9.68–4.34) | -1.026 ± 0.595* | 2.02 (2.02–2.03) | 9.73 (1 of 3) |
| 09-28 | ten, EPw, default window | -0.50 (-4.36–8.74) | -0.153 ± 0.44 | 1.44 (1.36–1.52) | 6.54 |

**WindowServer memory** (wsmem: `top` step when the widgets open, per widget; "ten" is 20 System widgets in the first
campaign and 10 in the second; the GPU's "in use" memory is the whole system's and moves by tens of MB on its own)

| campaign | scenario | mode | widgets | clean / rounds | WS MB per widget, clean rounds | WS open steps MB, all rounds | GPU in use MB per widget | process MB per widget |
|---|---|---|---|---|---|---|---|---|
| 09-27 | design | A | 5 | 3 / 5 | 1.00 (0.60–1.40) | [3, 5, 7, 1, 7] | 42.45 (40.30–45.25) | 41.30 (35.69–42.36) |
| 09-27 | design | D1, sRGB | 5 | 3 / 5 | 0.20 (0.00–1.60) | [8, 1, 1, 0, -1] | 4.94 (2.68–6.77) | 5.63 (5.48–5.70) |
| 09-27 | design | DP, sRGB | 5 | 0 / 5 | – | [4, 0, 5, 5, 3] | 4.43 (3.84–6.27) | 6.57 (6.53–6.59) |
| 09-27 | design | E1, sRGB window | 5 | 3 / 5 | 0.40 (0.00–0.60) | [0, 3, 2, 3, 3] | 5.51 (4.40–6.77) | 5.20 (3.31–5.54) |
| 09-27 | design | EP, sRGB | 5 | 1 / 5 | 0.00 | [-119, 0, 5, 5, 3] | 5.82 (-48.52–7.14) | 3.48 (3.34–3.50) |
| 09-27 | sixty | A | 5 | 0 / 5 | – | [1, -2, -1, 0, 1] | 4.61 (1.66–5.65) | 3.37 (3.17–3.77) |
| 09-27 | sixty | D1, sRGB | 5 | 1 / 5 | 0.00 | [0, 0, -5, 1, 1] | 2.40 (0.60–7.32) | 2.25 (1.95–2.32) |
| 09-27 | sixty | DP, sRGB | 5 | 2 / 5 | 0.60 (0.20–1.00) | [1, 0, 5, 1, -2] | 2.15 (1.54–5.73) | 3.90 (3.49–4.11) |
| 09-27 | sixty | E1, sRGB window | 5 | 2 / 5 | 0.10 (0.00–0.20) | [-3, 2, 0, 2, 1] | 2.58 (-0.11–4.53) | 1.97 (1.91–2.21) |
| 09-27 | sixty | EP, sRGB | 5 | 0 / 5 | – | [-4, -4, 5, 1, 4] | 2.72 (-0.06–5.69) | 1.96 (1.95–2.02) |
| 09-27 | ten | A | 20 | 5 / 5 | 0.45 (0.40–0.80) | [9, 8, 10, 16, 9] | 12.73 (12.25–13.21) | 11.96 (11.75–12.05) |
| 09-27 | ten | D1, sRGB | 20 | 1 / 5 | 0.10 | [2, 0, 1, 7, 4] | 1.72 (1.41–2.99) | 2.15 (2.13–2.35) |
| 09-27 | ten | DP, sRGB | 20 | 3 / 5 | 0.15 (0.15–0.40) | [-102, 3, 8, 3, 9] | 2.52 (-4.64–2.77) | 3.52 (3.49–3.65) |
| 09-27 | ten | E1, sRGB window | 20 | 3 / 5 | 0.20 (0.05–0.25) | [4, 1, 6, 5, 6] | 1.97 (1.04–2.31) | 1.85 (1.38–2.03) |
| 09-27 | ten | EP, sRGB | 20 | 5 / 5 | 0.10 (0.10–0.40) | [2, 2, 2, 8, 3] | 2.45 (0.96–8.84) | 1.96 (1.87–2.08) |
| 09-28 | design | A | 5 | 4 / 5 | 0.80 (0.20–1.20) | [6, 1, 45, 4, 4] | 42.50 (13.23–99.03) | 41.17 (35.71–41.29) |
| 09-28 | design | **B** | 5 | 4 / 5 | 1.00 (0.20–2.40) | [5, 1, 1, 12, 5] | 30.13 (4.93–37.32) | 1.21 (1.21–1.22) |
| 09-28 | design | **B+kept** | 5 | 4 / 5 | 1.00 (0.20–2.20) | [1, 7, -27, 3, 11] | 4.97 (-34.48–28.19) | 7.14 (7.06–7.14) |
| 09-28 | design | C1, default window | 5 | 4 / 5 | 0.40 (-0.20–1.20) | [-1, 3, -1, 1, 6] | 0.03 (-47.49–5.08) | 1.53 (1.49–1.73) |
| 09-28 | design | CPw, default window | 5 | 3 / 5 | 0.40 (0.40–0.60) | [2, 6, -32, 3, 2] | 1.83 (-15.50–4.49) | 3.21 (3.16–3.29) |
| 09-28 | design | E1, default window | 5 | 4 / 5 | 0.60 (0.40–1.00) | [3, 3, 2, 2, 5] | 4.33 (-2.04–14.86) | 5.40 (3.52–5.62) |
| 09-28 | design | EPw, default window | 5 | 3 / 5 | 0.60 (-0.40–0.60) | [-2, 3, 78, 3, 3] | 3.86 (-0.18–25.29) | 3.36 (3.30–3.56) |
| 09-28 | sixty | A | 5 | 3 / 5 | -0.40 | [-2, -2, -58, -2, 1] | -22.98 (-24.81–2.73) | 3.09 (3.08–3.12) |
| 09-28 | sixty | **B** | 5 | 3 / 5 | 0.00 (-0.20–0.60) | [2, 0, 3, 4, -1] | 1.36 (-2.31–42.46) | 1.37 (1.18–1.53) |
| 09-28 | sixty | **B+kept** | 5 | 4 / 5 | 0.10 (0.00–0.20) | [0, 1, -2, 0, 1] | -5.26 (-51.18–1.08) | 1.81 (1.38–1.85) |
| 09-28 | sixty | C1, default window | 5 | 5 / 5 | -0.20 (-0.40–0.20) | [0, -2, -1, -2, 1] | 0.47 (-27.21–2.67) | 1.21 (1.09–1.33) |
| 09-28 | sixty | CPw, default window | 5 | 4 / 5 | -0.10 (-0.20–0.40) | [2, -1, -1, 0, -1] | 1.44 (0.52–94.05) | 3.21 (3.14–3.22) |
| 09-28 | sixty | E1, default window | 5 | 4 / 5 | 0.20 (0.20–0.40) | [1, 1, 1, 2, 0] | 0.69 (-18.19–3.80) | 2.01 (2.00–2.14) |
| 09-28 | sixty | EPw, default window | 5 | 2 / 5 | 0.50 (0.40–0.60) | [4, 3, 3, 2, 38] | 2.67 (-0.26–9.58) | 1.93 (1.89–1.96) |
| 09-28 | ten | A | 10 | 3 / 5 | 0.50 (-0.20–0.70) | [-2, 7, 10, 5, 5] | 20.69 (7.94–29.91) | 19.92 (17.07–20.41) |
| 09-28 | ten | **B** | 10 | 4 / 5 | 0.45 (-0.10–0.90) | [4, 1, -1, 9, 5] | 2.50 (-1.74–3.08) | 0.64 (0.63–1.19) |
| 09-28 | ten | **B+kept** | 10 | 4 / 5 | 0.35 (-0.10–0.70) | [-1, 5, 2, 7, 8] | 1.50 (-9.95–9.11) | 3.75 (3.74–4.05) |
| 09-28 | ten | C1, default window | 10 | 5 / 5 | 0.20 (-0.20–0.30) | [-1, 2, 3, 2, -2] | 0.82 (-0.23–0.84) | 0.81 (0.80–0.82) |
| 09-28 | ten | CPw, default window | 10 | 5 / 5 | 0.20 (0.10–1.20) | [2, 3, 12, 1, 1] | 1.81 (0.80–16.51) | 3.00 (2.99–3.00) |
| 09-28 | ten | D1, sRGB | 10 | 2 / 5 | 0.00 | [1, 0, -1, 3, 0] | 1.16 (0.73–14.18) | 2.35 (2.29–2.36) |
| 09-28 | ten | E1, default window | 10 | 4 / 5 | 0.25 (0.00–0.30) | [2, 3, 0, 2, 3] | 2.19 (-26.44–2.70) | 2.23 (1.50–2.29) |
| 09-28 | ten | E1, sRGB window | 10 | 5 / 5 | 0.10 (0.00–0.20) | [2, 1, 1, 0, 1] | -0.83 (-10.55–2.58) | 2.21 (1.44–2.24) |
| 09-28 | ten | EP, sRGB | 10 | 4 / 5 | 0.10 (-0.10–0.30) | [0, 2, -5, 3, -1] | 2.13 (-9.60–17.17) | 1.97 (1.96–2.27) |
| 09-28 | ten | EPw, default window | 10 | 3 / 5 | 0.10 (0.10–0.20) | [1, -1, 2, 1, -3] | 1.07 (-12.12–10.35) | 2.29 (2.02–2.33) |
| 09-28 | ten | EPxw, default window | 10 | 3 / 5 | 0.20 (0.10–0.40) | [3, 2, 65, 4, 1] | 2.09 (1.65–22.40) | 3.47 (3.15–3.50) |

**What the memory numbers mean**

- **A holds 120–160 MB as soon as a skin redraws.** Core Animation rasterizes A's display list in this process on its
  accelerated path, and that path keeps about 113 MB of graphics memory ("Owned physical footprint (unmapped)
  (graphics)") plus IOSurfaces: one design skin +123 MB, ten System widgets +155 MB (15.5 MB each). It does not depend
  on the update rate (`memtrace/design-A-every-*`: 163–165 MB whether the skin redraws every 16.7 ms or every 1 s) and
  appears after the first redraws: ten System widgets drawn once and never again stayed at +17.8 MB
  (`memtrace/static-A`). This is what made Deskset move to B.
- **B's own bitmaps are not in its footprint**: two 0.78 MB bitmaps per System widget, yet +0.24 MB per widget (see
  Conditions: the pages of a bitmap whose image went to the window server leave the process). B+kept's pictures are
  drawn once and then read every frame when they are copied, so they stay: +3.38 MB per System widget (own bitmaps
  4.67 MB: the two bitmaps and four pictures), +6.33 MB for the design skin (9.89 MB: two bitmaps and three
  pictures of 1.98 MB).
- **E layers** are charged as "CoreAnimation" (backing stores; CA gives layers that keep changing a second buffer, and
  marks one of them volatile) and the partition's base bitmap and base crops as "CG raster data". EPw: 2.17 MB per
  System widget (partition minimum, window + group boxes: 1.25 MB), 2.70 MB for the design skin. The scratch bitmap
  (EPxw) adds about one window bitmap: 3.44 MB and 5.27 MB.
- **C**'s bitmaps behave like B's: C1 +0.88 MB per System widget (own bitmaps 1.55 MB), +0.25 MB for the design skin.
  The partition CPw keeps the base bitmap and two bitmaps per group (own 1.73 MB per System widget): +2.82 MB
  (one skin thread: 2.46 MB), +2.19 MB for the design skin.
- **D** (first campaign) is charged in full for its IOSurfaces (up to 3 per layer): 2.35 / 3.49 MB per System widget
  (D1 / DP), 4.42 / 5.69 MB for the design skin.
- Hiding the windows (ordered out for 5 s in `memtrace-b`) raised every mode's footprint while hidden (EPw +2 MB,
  E1 +8 MB, B +15 MB for 10 widgets) until they were shown again: the spike does not release anything when hidden,
  unlike the plan, which releases every layer's contents while a skin is hidden.

**What the CPU numbers mean**

- **With one thread per widget and all widgets updating at the same moment** (every run in the tables unless marked),
  10 System widgets updating every second cost: the partitions 1.13 % (DP) – 1.24 % (CPw) – 1.45–1.51 % (EP / EPw) of
  one core, the scratch variants 1.72–1.91 %, one layer (E1, C1, D1) and B drawn in full 1.56–2.08 %; today's B+kept
  0.75 % and A 0.62–0.78 % (both on the main thread). At 60 Hz: B+kept 3.98 %, CPw 4.07 %, DP 4.18 %, EPw 5.57 %,
  E1 6.49 %, B 7.73 %, A 8.11 %. The design skin is cheap in every mode that redraws only what changed (0.09–0.15 %).
- **Most of the partition's cost in the 10-widget runs comes from the ten threads, not from the layers.** The same 10
  widgets on **one shared skin thread**, updating one after another: EPw **0.62 %**, CPw **0.58 %** (below B+kept),
  E1 1.41 %, C1 1.50 %. On ten threads with their updates **spread over the second** instead of at the same moment:
  EPw 1.03 %, E1 1.85 %. Per widget update, EPw draws in 1,481 µs and commits in 386 µs on ten simultaneous threads,
  700 µs + 88 µs on ten spread threads, 447 µs + 51 µs on one thread. The process's CPU time drops with it, so this
  is not only waiting for locks; likely causes are short bursts on cores that are not ramped up or on efficiency
  cores, and contention in Core Animation's commit path (commit time falls 7.6×). The spike does not separate them.
  Deskset's threading plan gives every skin its own thread: this deserves a measurement in the real engine (its
  skins' timers are not aligned, which is the "spread" case).
- One layer drawing the whole skin shows the same effect: 2,014–2,023 µs per System widget for E1 and C1 on ten
  simultaneous threads, 1,235–1,279 µs on one thread, 1,384 µs for B on the main thread (the same pixels into the same
  kind of bitmap).
- The partition otherwise pays per layer: the commit of 19 group layers and 38 tiles (51–62 µs on one thread) against
  22–31 µs for one layer; C's commit is a little dearer than E's, its drawing a little cheaper (60 Hz: 482 + 134 µs
  vs 636 + 189 µs per frame).
- Wakeups (interrupt wakeups of this process per second, all widgets together): 1.4–4.6 for 10 widgets updating at the
  same moment or on one thread (EP16: 6.5), 12.5–13.3 when their updates are spread over the second (each widget wakes
  its own thread), 1.6–1.8 for B, 5.7–6.8 for A; 60–80 at 60 Hz (A: 230–340).
- **WindowServer's CPU** does not change measurably with 10 widgets updating every second: the mean increase per
  on / off pair is between −1.0 and +0.23 % of a core in every mode, none further from 0 than two standard errors
  (0.2–0.6 %; single pairs move by ±5 %). At 60 Hz the means range from −5.5 to +2.1 % with no consistent sign between
  modes or campaigns (the partition: +1.7 ± 0.3 % in the first campaign, −1.0 ± 0.2 % in the second; the views drawn
  on the main thread show large negative outliers): this screen's WindowServer (45–56 % of a core with nothing of
  ours on screen) hides anything below about 2 % of a core at 60 Hz.
- 60 Hz frames: every mode delivered 298–300 of 300 committed frames to the screen in 5 s (the lowest single rounds:
  EPw 291, CPxw 294), commit intervals p50 16.67 ms, p99 17.1–21.6 ms.
- Opening (all widgets built and their first frame committed): 10 System widgets in 46–86 ms in every layered mode
  (A and B 12–31 ms), one design skin or visualizer in 2–15 ms.

**Against the plan's targets**

| target | E (EPw) | C (CPw) | D (DP, sRGB) | today's B+kept | A |
|---|---|---|---|---|---|
| default skin ≤ 2 MB per idle widget (measured: System widget updating every second) | 2.17 (one thread: 1.89) | 2.82 (2.46) | 3.49 | 3.38 | 15.5 |
| design skin ≤ 2.5 × one bitmap (4.95 MB) and ≤ 6 MB | **2.70** | **2.19** | 5.69 ✗ | 6.33 ✗ | 123 ✗ |
| WindowServer ≤ A's increase + 1 MB (A: 0.45–0.50 per System widget, 0.8–1.0 per design skin) | 0.10 / 0.60 | 0.20 / 0.40 | 0.15 / – | 0.35 / 1.0 | – |
| 10 widgets: this process < 1 % of a core | 1.51 ✗ (spread 1.03, one thread **0.62**) | 1.24 ✗ (one thread **0.58**) | 1.13 ✗ | **0.75** | **0.62–0.78** |
| 10 widgets: WindowServer < 1 % | yes (−0.15 ± 0.44) | yes (−0.36 ± 0.27) | yes (0.08 ± 0.19) | yes (0.22 ± 0.46) | yes |
| ≤ 12 wakeups per second | 3.7 (spread: 13.3) | 1.4 | 1.4 | 1.6 | 5.7–6.8 |
| opening to first frame < 100 ms | 68 ms for 10 | 60 ms | 77 ms | 24 ms | 12–31 ms |
| 60 Hz visualizer | 299 / 300 frames, 5.57 % | 300 / 300, 4.07 % | 299 / 300, 4.18 % | 300 / 301, 3.98 % | 299 / 300, 8.11 % |

(CPU numbers from runs with a load above 8 are provisional, see the tables; the medians of the combinations measured
in both campaigns, A and one E layer, agree within 0.16 % of a core.)

## 4. Color: the `draw(in:)` context, formats and color spaces (`q4-default.json`, `q4-srgb.json`, `q4-p3.json`)

**The context `draw(in:)` gets is a bitmap context in the window's color space**, not sRGB and not the display list A
gets (`kCGContextTypeDisplayList`). Its depth follows `contentsFormat`. B's own bitmap is in the window's color space
too (Deskset's choice), so it gets the same pixels as an 8-bit E layer:

| window color space | what | context | backing store after 3 more frames |
|---|---|---|---|
| default (the screen's "Color LCD") | E, RGBA8Uint | bitmap, Color LCD, 8 bpc (skin thread) | `BGRA8888`, 2 buffers |
| default | E, RGBA16Float | bitmap, Color LCD, 16 bpc float | `RGBAh`, 2 buffers |
| default | E, format not set | `kCGContextTypeCoreAnimationAutomatic` | `RGBA16` (16-bit integer), 2 buffers |
| default | B (own bitmap) | bitmap, Color LCD, 8 bpc (main thread) | a `CGImage` |
| default | A | display list (main thread) | – |
| sRGB | E, RGBA8Uint | bitmap, sRGB, 8 bpc | `BGRA8888`, 2 buffers |
| sRGB | E, RGBA16Float | bitmap, extended sRGB, 16 bpc float (some group layers: sRGB, 16 bpc float) | `RGBAh`, 2 buffers |
| sRGB | E, not set | automatic | `BGRA8888`, 2 buffers |
| sRGB | B | bitmap, sRGB, 8 bpc | a `CGImage` |
| Display P3 | E, RGBA8Uint / RGBA16Float / not set | Display P3, 8 bpc / 16 bpc float / automatic | `BGRA8888` / `RGBAh` / `RGBA16`, 2 buffers each |
| Display P3 | B | bitmap, Display P3, 8 bpc | a `CGImage` |

Small group layers (the 14 × 28 px core bars and a 66 × 34 px value) ended up with a `CGImage` as `contents` instead
of a backing store after a few frames; CA does this on its own.

If an E layer is displayed in the same transaction that adds it to a window's tree (before the window's context knows
the layer), its first `draw(in:)` runs on the skin thread in sRGB and CA then draws it **again on the main thread** in
the window's color space (1 of 1 E1 layers, 10 of 19 EP groups). Committing the tree first and displaying in the next
transaction avoids it; the spike does that everywhere else.

Which combination brings E closest to A and to today's B (System widget, one E layer; A and B in the default window):

| E layer | vs A | vs B (today) |
|---|---|---|
| default window, RGBA8Uint | max 6, 84.32 % | **0** (identical) |
| Display P3 window, RGBA8Uint | max 6, 84.32 % | **0** (identical; B in a P3 window also equals B in the default window) |
| default window, RGBA16Float | **0** (identical) | max 6, 84.32 % |
| Display P3 window, RGBA16Float | max 1, 0.27 % | max 6, 84.34 % |
| default window, format not set (RGBA16) | max 5, 1.58 % | max 3, 84.34 % |
| sRGB window, RGBA16Float (extended sRGB) | max 4, 11.61 % | max 6, 85.33 % |
| sRGB window, RGBA8Uint (= D1, = A and B in an sRGB window) | max 10, 87.24 % | max 9, 53.81 % |

The partition in the same combinations: with RGBA8Uint in the default window and the base bitmap in the window's
color space, max 1 in 7 px (0.003 %) against B; with an sRGB 8-bit base, max 1 in 48.18 %. With RGBA16Float in the
default window and the base drawn in the window's color space at 16-bit float, max 1 in 8 px (0.004 %) against A; with
an sRGB 8-bit base, max 2 in 77.16 %. The partition matches the single layer whenever the base bitmap is in the same
color space and depth as the E contexts (7–10 px of translation noise in every window color space tried); otherwise
48–77 % of the pixels differ by 1–2.

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

## 8. Offscreen `CARenderer` on the CI runners (`../ci-probe/`, `ci-probe/*.json`)

The planned pixel gate G2 renders two layer trees offscreen with `CARenderer` (one layer showing the whole skin, and
the partition) and compares them. `ci-probe/main.swift` is a minimal version of that, run by `ci-probe/run.sh` here
and by `.github/workflows/h1-probe.yml` on both runners for every push to this branch. It renders seven trees at 1×
and 2× (320 × 240 pt, so 640 × 480 px at 2×) into an sRGB `BGRA8Unorm` Metal texture, clears the texture before every
render, waits for the GPU, reads the texture back (top row first) and hashes it:

| scene | what | layers |
|---|---|---|
| `image` | an image made from integer math (opaque, translucent and clear areas) shown pixel for pixel | 1 |
| `solids` | flat colors, translucent and overlapping, and a group with opacity | 8 |
| `vector` | what Core Animation draws itself: rounded corners, border, shadow, shape layer, rotation, gradient layer, mask, fractional positions | 10 |
| `cg` | a CoreGraphics bitmap (gradient, translucent rounded panel, hairlines, Helvetica text) as contents | 1 |
| `g2-single` | a widget (StylePanel-like gradient panel, time, bar, ring, chart, list) as one layer showing one bitmap | 1 |
| `g2-tiles` | the same widget partitioned: 15 base tiles sharing one base image through `contentsRect`, 5 group bitmaps | 20 |
| `g2-e` | the same partition with group layers that paint in `draw(in:)` (E; their context was sRGB, 8 bpc, everywhere) | 20 |

It checks `image` and `cg` and `g2-single` against their source bytes and both partitions against `g2-single`,
compares every scene with this Mac's run (`ci-probe/local-arm64/`, the pixels deflate-compressed), and times the
partitioned widget: three rounds of 20 renders each, in four ways, with the texture overwritten with garbage before
every render and every read-back required to hash like the first. Each machine ran it three times: this Mac
natively three times and once as an x86_64 build under Rosetta (`local-*.json`), each runner three times (workflow run
36383643743, attempts 1–3, `ci-36383643743-attempt*.json`). The 1-minute load average stayed between 1.6 and 7.3 in
every timed round, so nothing is provisional. (Run 36383370736, `ci-36383370736-*.json`, was the probe before the
read-back fix below; its arm64 load was 16–23.)

| | this Mac | `macos-26` | `macos-26-intel` |
|---|---|---|---|
| machine | Mac16,8, Apple M4 Pro, 14 cores | VirtualMac2,1, "Apple M1 (Virtual)", 3 cores, 7 GB | a virtual machine reporting Macmini6,2, Intel Core i7-8700B, 4 cores, 14 GB |
| macOS | 26.5.2 (25F84) | 26.6.2 (25G83) | 26.6.1 (25G76) |
| `MTLCreateSystemDefaultDevice()` | Apple M4 Pro | **Apple Paravirtual device** (unified memory, family `mac2` only, 4.8 GB working set) | **Apple Paravirtual device** (no unified memory, no GPU family, 1 GB working set) |
| display | built-in XDR, 1512 × 982 pt | 1024 × 768 | 1920 × 1080 |

**Both runners can composite offscreen.** Every scene rendered on both, the read-backs are not the bytes written
before the render, and every scene hashes the same in all three runs of a runner (three separate virtual machines).
Within a run, what G2 compares is exact on both runners:

| check (1× and 2×) | this Mac | `macos-26` | `macos-26-intel` |
|---|---|---|---|
| `image` == its source; `cg`, `g2-single` == their source bitmaps | 0 | 0 | 0 |
| `g2-tiles` == `g2-single` | 0 | 0 | 0 |
| `g2-e` == `g2-single` | 0 | 0 | 0 |
| the G2 trees rendered a second time, and `g2-tiles` 240 more times per run (4 ways × 3 rounds × 20) | same bytes | same bytes | same bytes |
| `vector` rendered a second time | same bytes | same bytes | **max 1 in 301 px (0.098 %) at 2×** in all three runs (the second render differs from the first the same way each time); at 1× 0, 4 and 4 px |

**Two traps, both silent:**

- `CARenderer` composites over whatever the texture holds: it does not clear it. Found here first (translucent pixels
  showed the previous render). The probe clears with an empty Metal render pass before every render.
- The Intel runner's device has no unified memory. A texture with `.shared` storage can be created there, but the
  GPU's writes never reach the CPU's copy: in run 36383370736 every read-back was the garbage written before the
  render, so every scene "failed" its source check, and **every comparison of two trees said identical** (the same
  garbage on both sides). With `.managed` storage and a blit `synchronize(resource:)` before `getBytes` it works.

**Against this Mac** (arm64 build unless stated; "max" in 8-bit levels, share of differing pixels at 1× / 2×):

| scene | `macos-26` | `macos-26-intel` | this Mac, x86_64 under Rosetta | `macos-26-intel` vs this Mac under Rosetta |
|---|---|---|---|---|
| `image` | 0 | 0 | 0 | 0 |
| `cg` | 0 | max 1, 3.4 / 2.5 % | max 1, 3.4 / 2.5 % | **0** |
| `g2-single`, `g2-tiles`, `g2-e` | 0 | max 2 / 1, 17.7 / 16.9 % | max 2 / 1, 17.7 / 16.9 % | **0** |
| `solids` | 0 | max 1, 29.7 / 29.7 % | max 1, 33.6 / 33.6 % | max 1, 3.9 / 3.9 % |
| `vector` | max 1, 0.20 / 0.65 % | max 8 / 3, 9.3 / 9.0 % | max 1, 12.5 / 12.0 % | max 8 / 3, 15.2 / 15.2 % |

- **CoreGraphics' output depends on the CPU architecture of the process, not on the machine**: the x86_64 build gets
  the same bytes on the Intel runner and under Rosetta here, the arm64 build the same bytes here and on `macos-26`;
  between the two, text, gradients and antialiased edges differ by 1–2 levels in 2.5–18 % of the pixels.
- **Core Animation's own drawing depends on the architecture and on the GPU**: translucent flat colors and group
  opacity differ by 1 between the architectures (and by 1 in 3.9 % between the Intel runner and Rosetta here);
  shapes, shadows and gradient layers by up to 8 on the Intel runner, by 1 in under 1 % on `macos-26`.
- **Bitmaps shown pixel for pixel (nearest filtering, whole-pixel positions) come through exactly everywhere.** That
  is all a G2 tree contains: base tiles, group bitmaps and the glass stand-ins baked into the base.

**Time per render** (median of the 9 round medians per machine, range of the round medians in parentheses; each round
20 renders; the widget partitioned into 20 layers; "render" includes clearing and waiting for the GPU):

| way | this Mac | `macos-26` | `macos-26-intel` | this Mac, Rosetta |
|---|---|---|---|---|
| the same tree again, 2× | 0.20 ms (0.19–0.24) | 1.39 ms (0.59–1.58) | 1.81 ms (1.66–2.78) | 0.55 ms |
| the same tree again, 1× | 0.18 ms (0.17–0.19) | 1.12 ms (0.64–1.69) | 1.19 ms (1.11–1.76) | 0.44 ms |
| a new tree each time (built, attached, committed, rendered), 2× | 0.49 ms (0.44–0.58) | **3.39 ms** (1.52–4.19) | **7.03 ms** (6.45–11.97) | 1.03 ms |
| a new texture and renderer each time, 2× | 0.88 ms (0.84–0.94) | 21.7 ms (12.0–22.9) | 9.26 ms (8.53–14.81) | 1.85 ms |
| read-back and flip, 2× | 0.44 ms | 0.72 ms | 0.26 ms | 5.06 ms |
| first render in the process | 5–8 ms | 111–209 ms | 139–724 ms | 57 ms |

The plan budgets about 10,000 renders for the G2 matrix at 5–20 ms each. With one renderer and texture per size and a
new tree per render, the measured cost is about 4 ms per render on `macos-26` and 7.3 ms on `macos-26-intel`
including the read-back (less at 1×): roughly 40 s and 75 s of `CARenderer` time, far inside the 10 and 20 minute
caps. A new renderer per render would cost about 22 ms on `macos-26` (almost 4 minutes). Building the skins' scenes
and bitmaps, which the probe does not measure, will be the larger part.

**For G2 on CI:**

1. Run it on both runners. Compare only trees rendered in the same run; keep no reference pixels from another machine,
   architecture or macOS version (the runners were already on 26.6.x while this Mac is on 26.5.2).
2. Clear the texture before every render; on a device without unified memory use a managed texture and synchronize
   it before reading back.
3. Start the suite with a canary that must come back byte for byte (an image layer against its source, like the
   probe's `image` scene) and a check that the read-back is not what was written before the render; if either fails,
   the suite has not run (the plan's "not run", exit 4), it has not passed.
4. Keep G2's trees to bitmap contents. Content that Core Animation draws itself (a later Desk-native shape) is not
   stable from one render to the next on the Intel runner (1 level in 0.1 % of the pixels, at the edge of G2's
   tolerance) and would need its own tolerance or a render-twice rule.
5. Reuse one `CARenderer` per texture size and attach each new tree; the Intel subset fallback is not needed for
   rendering time.

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
refreshed 25 times per variant and round while a sampler read back the window's area about 240 times per second,
compositing only those of our windows that the window server reported on screen, and classified each capture by the
alpha at four points of the panel: blank (no panel), doubled (two panels, more opaque than one), or normal. The new
window's first frame is committed before it is shown.

| variant (25 swaps per round, 3 rounds) | captures per round | blank | doubled | dropped (window list changed during the capture) | swap takes (p50) |
|---|---|---|---|---|---|
| new window ordered above the old one, then the old one out | 1,435 / 1,439 / 1,490 | 0 | 0 | 20 / 17 / 20 | 57.5 ms (57.3–57.9) |
| old window out, then the new one in | 1,454 / 1,356 / 1,277 | 0 | 0 | 17 / 11 / 16 | 58.6 ms (57.8–59.7) |
| both inside `NSDisableScreenUpdates` | 1,419 / 1,283 / 1,106 | 0 | 0 | 20 / 19 / 22 | 58.5 ms (57.7–61.1) |
| same window, `contentRoot`'s layers replaced in one transaction | 1,098 / 1,130 / 851 | 0 | 0 | 0 | 7.3 ms (7.2–7.4) |

- No capture showed a blank or doubled window. A capture that straddled a swap (the window list changed between the
  check before and after it) is dropped, so a state shorter than one capture (about 4 ms, less than one display
  frame) cannot be ruled out by this method; nothing longer happened.
- Replacing the tree inside the same window needs no window-list change and takes 7 ms instead of 58 ms (a new window
  with a new layer tree and its first frame).
- The 1-minute load at the end of the rounds was 6.3, 12.4 and 16.4: the swap times of rounds 2 and 3 are provisional
  (the blank / doubled counts do not depend on it).
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

- A 1× external display, an sRGB display, and moving a window between screens (only the built-in XDR display here).
  With E layers in the window's color space (like B), a window moved to a screen with another color space needs its
  base bitmap drawn again; B already does this (Deskset draws kept pictures again when the display's color space
  changes).
- WindowServer's memory from `footprint` or `vmmap`: both, and `proc_pid_rusage`, need root for WindowServer
  ("try running with `sudo`"; `sudo` needs a password here), so it comes from `top` (MEM, 1 MB resolution), with
  WindowServer's resident size from `ps` and the GPU's memory in use from the I/O Registry as cross-checks.
- The real `NSGlassEffectView` in the glass check is only timed: its tint is not a flat color, so the read-back cannot
  tell whether it lags behind the element (the stand-in view can).
- D with IOSurfaces in the display's color space (it should match B like E does).
- Click-through (steps above).
