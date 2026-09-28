# H1: a skin as many Core Animation layers instead of one bitmap — results

Measured on 2026-09-27 and 2026-09-28 with the spike in this folder (`run.sh`, then `python3 summarize.py`). Every
number below comes from a JSON file next to this one; each section names its files. Questions 1–7 and the side checks
of the H1 experiment are answered here, and question 8 (a `CARenderer` probe on the CI runners, `../ci-probe/`,
measured on the runners on 2026-09-28) in its own section.

**Corrected after a review (2026-09-28, afternoon).** The review found 25 problems: memory compared through
`phys_footprint`, which does not see images handed to the window server; WindowServer memory read from `top`, which
cannot see layer contents; memory-pressure and interleaving claims the raw data contradicts; a 60 Hz rule that H1's own
numbers already triggered; a CI check that was exact by construction; a B baseline that is not what Deskset ships; an
A baseline that is not what updating skins looked like; and several overstated figures. The affected sections say
what changed; new measurements are in `q1-stepped.json`, `q5-review-search*.json`, `q5-partitions/`, `sysmem/`,
`cost-d/`, `wspair/`, `frames60/`, `cschange/` and `ci-probe/local-*-plan-groups.json`.

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
- Memory pressure (corrected after review): **not** level 1 in every run. `memoryPressureAfterSettle.pressureLevel`
  was 2 in 5 of 51 first-campaign cost runs and 36 of 99 second-campaign runs (every round of `ten-A`, `ten-B`,
  `ten-Bkept` and `ten-E1`, and rounds 1–2 of most design and sixty combinations), with 0.05–8.5 GB free. The level
  is confounded with the mode (no C run reached level 2, most E runs did), and level-2 rounds read lower (design E1
  3.14 / 3.64 MB at level 2 vs 4.41 at level 1; design EPw 2.28 / 2.70 vs 3.03). The tables below give phys_footprint
  medians of level-1 rounds where there are any, and mark the rest; the memory comparisons use the measurement
  added after review (below), which records the level of every sample.
- `phys_footprint` does not see the pages of `CGImage`s made from bitmap contexts while Core Animation has handed them
  to the window server: 8 such images of 9.77 MB each in an sRGB window add 0.34–0.8 MB to it, and B's two bitmaps
  per System widget come back into it only while the windows are ordered out (`memtrace-b/ten-B.json`: 2.6 MB shown,
  17.66 MB hidden, 2.66 MB shown again: +15 MB = 10 × two 0.78 MB bitmaps; `memtrace-b/design-B.json`: +2.3 MB for
  8 s, then +0.4 MB, 4.3 MB hidden). The pages are still in memory. (An earlier version of this paragraph also
  quoted a design-skin B trace of +1.86 MB then −0.1 MB and a `vmmap` listing; no committed file holds them, so they
  are withdrawn.) So modes that hand over images (B, C, and the partition's base) look cheaper by phys_footprint than
  modes whose pixels live in CA backing stores or IOSurfaces. After review, memory is compared with
  **`footprint --vmObjectDirty`** of the spike's own process (no root needed), which counts every dirty page of the
  VM objects mapped into it, including those the window server maps too. It passes the positive control that every
  other reading here fails: 8 separate copies of a 9.77 MB random-pixel image in an sRGB window add +78.7 MB
  (8 × 9.77 = 78.1), one image +10.2 MB, an empty window +0.4 MB (`sysmem/control-*.json`). Memory is also given as the
  uncompressed bytes of the bitmaps the layers or the view hold ("layer bitmaps", "own bitmaps"), each buffer counted
  once.
- WindowServer's memory is **not measured** (corrected after review). `footprint`, `vmmap` and `proc_pid_rusage`
  need root for WindowServer; `top`'s MEM stays at +12–13 MB for one image, 61 tiles sharing it, and 8 separate
  copies (78 MB of distinct pixels), so it follows the window's surface, not the layers' contents; the GPU's memory
  in use and system-wide page counts (anonymous + wired + compressed) moved by tens to thousands of MB on their own on
  this machine and did not show the 8 copies either (`sysmem/control-*-gpu-quiet-wait.json`: GPU steps −20…+24 MB,
  system steps +440…+1,430 MB for +78 MB). `run.sh wsfootprint-person` measures it with `sudo footprint` for a person
  who types the administrator password once.
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
  were placed on screen. Everything added after review is from the afternoon of 2026-09-28.

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
| 1 | partition vs one E layer vs A, read back from the screen (built-in XDR display, 2×, color space "Color LCD" ≈ Display P3) | **The partition equals one E layer when its base bitmap is in the E contexts' color space: max 1 in 7 px (0.003 %)**, all from CoreGraphics' whole-pixel translation of curved paths, and **0** when the groups are drawn through a window-sized scratch bitmap — in an sRGB window with an sRGB base, and in the default window with the base in the window's space. An sRGB base in the default window: max 1 in 48 %. **One E layer in the default window is identical to B drawn in full; it differs from what Deskset draws (B+kept) by max 1 in 0.68 %** (B+kept's own rounding). Against A drawn once: max 6 in 84 %; against A as it looked while updating (Core Animation's accelerated path): max 102 in 85 %. An sRGB window changes about 54 % of B's pixels, 99.9 % of them by 1–2 levels (outliers up to 9 in 0.05 %). Overlapping layers (reproduced): max 2–4 in 7–25 %. |
| 2 | E vs D | Identical (0) in an sRGB window; in the default window max 9 in 54 % (E follows the window's color space, D's surfaces are sRGB). Partition with IOSurfaces vs one IOSurface: max 1 in 7 px; through the scratch bitmap 0. Memory and CPU: question 3 (D costs more memory than E; C, our own bitmaps as `CGImage` contents, is in question 3 too). |
| 3 | memory and CPU at 2× | This process, per widget updating every second: the partition 2.17 MB (E) / 2.82 MB (C) / 3.49 MB (D) for a 260 × 196 pt System widget, 2.70 / 2.19 / 5.69 MB for the 360 pt design skin; one E layer 2.22 / 3.64 MB; today's B+kept 3.38 / 6.33 MB; A 15.5 / 123 MB (its accelerated path). WindowServer: at most +1.0 MB per widget in every way, no more than A or B (`top`; `footprint` and `vmmap` need root). CPU for 10 System widgets: **0.58–0.62 % when their updates run on one thread** (C / E partition; B+kept 0.75 %, A 0.62–0.78 %), but 1.24–1.51 % with one thread per widget updating at the same moment and 1.03 % spread over the second; WindowServer's CPU: no measurable change. Wakeups 1.4–4.6 per second for all 10 (13 when spread). 60 Hz visualizer: 298–300 of 300 frames on screen in every way; CPU C 4.07 %, D 4.18 %, E 5.57 %, B+kept 3.98 %, A 8.11 %. |
| 4 | the `draw(in:)` context and formats | A bitmap context (`kCGContextTypeBitmap`, data in this process) **in the window's color space** ("Color LCD" by default, sRGB in an sRGB window, Display P3 in a P3 window) — not always sRGB. 8 bpc for `RGBA8Uint`, 16 bpc float for `RGBA16Float` (extended sRGB in an sRGB window), `kCGContextTypeCoreAnimationAutomatic` when no format is set; A gets a display list. **Closest to B (drawn in full): `RGBA8Uint` in the default (or a P3) window: identical** (B+kept differs from it by max 1 in 0.68 %). Closest to A drawn once: `RGBA16Float` in the default window: identical (not to A as it looked while updating, question 1). The plan's `RGBA8Uint` in an sRGB window: max 9 in 54 % from B, max 10 in 87 % from A, identical to D. |
| 5 | gradients cut at box edges (pure CG) | 270° StylePanel gradient cut by a 100 × 30 pt box: max 1 in 70.8 % of the box; over all positions median 67.9 %, 0–84 %: **the effect is reproduced (about two thirds of the pixels off by 1), the review's figures (64.4 / 57.2 / 59.9 %) are not**: no box position gives all three. Box at the panel's top left, translation only, solid translucent panel: 0. **Whole-window base bitmap + whole-pixel sub-rectangles: 0.** Whole partitions: max 1 in ≤ 0.009 % at 1× and 2×, arm64 and x86_64. |
| 6 | base tiles sharing one image | **Counted once** (measured after review with `footprint --vmObjectDirty`, which sees the pages): 61 tiles sharing a 9.77 MB image add +10.2 MB in an sRGB window, exactly what one layer with it adds, while 8 separate copies add +78.7 MB; in the default window CA's color-converted copy is made once for all 61 tiles (+20.0 MB) and once per separate image (8 copies +156.9 MB). WindowServer's share was not measured (`top` cannot see it). **Read back byte for byte**: 0 differing pixels offscreen (`CARenderer`) and on screen (vs one layer). |
| 7 | ContentHost flipping | All markers in place in 5 of 5 captures over 4 resizes; **AppKit wrote to `contentRoot` 0 times** (25 times to a layer-hosting root). Screen change not tested (one screen). |
| 8 | offscreen `CARenderer` on the CI runners | **Both runners have a Metal device** ("Apple Paravirtual device" on `macos-26` and on `macos-26-intel`) and render every tree. Within a run, partitions made of pixels **copied from the one-layer bitmap** are identical to it on both (true by construction: it shows that CA composites copied pixels exactly). The partition drawn the plan's way (added after review) was run only here, arm64 and x86_64 under Rosetta (the Intel runner's CoreGraphics output): max 1–2 in 2–3 px, all CoreGraphics translation noise, CA adds nothing; the runners run it on the next push. Against this Mac: `macos-26` is byte-identical for bitmaps and flat colors (Core Animation's own shapes: max 1 in 0.2–0.65 %); `macos-26-intel` differs everywhere except copied bitmaps (CoreGraphics output depends on the CPU architecture). Two silent traps: `CARenderer` does not clear the texture, and on the Intel runner a shared texture never sees the GPU's writes. Per render at 2× (a new 20-layer tree each time, one renderer), round medians: 1.5–4.2 ms on `macos-26`, 6.5–12.0 ms on `macos-26-intel` (most rounds provisional by load per core), 0.5 ms here. |
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
| E1 vs **B** (drawn in full) | **0** | max 9, 53.81 % (E1 in an sRGB window vs B in the default window) |
| EPw vs B / EPxw vs B | max 1, 7 px / **0** | – |
| C1 / CPw / CPxw (our own bitmaps as contents) vs B | **0** / max 1, 7 px / **0** | C1 / CP vs E1: 0 / max 1, 7 px |
| E1 / EPxw / C1 vs **B+kept** (what Deskset draws; after review, `q1-stepped.json`, stepped from tick 0 to 7) | max 1, 1,393 px (0.68 %); EPw and CPw 1,400 px | – |
| B vs A | max 6, 84.32 % | 0 (B and A both in an sRGB window) |
| E1 vs A | max 6, 84.32 % | 0 (in an sRGB window); vs A in the default window: max 10, 87.24 % |
| A in an sRGB window vs A in the default window | – | max 10, 87.24 % |
| OVE (overlapping E layers) vs E1 | max 2, 6.80 % (inside group boxes 11.28 %) | max 3, 12.15 % (20.15 %) |
| OVD (overlapping own bitmaps) vs D1 | max 4, 24.94 % (31.88 %) | max 3, 12.15 % (20.15 %) |

- **The partition can equal one E layer and B drawn in full, pixel for pixel.** In the default window, an E layer's
  context is in the window's color space (question 4), exactly like B's own bitmap: E1 and B drawn in full are
  identical. A partition whose base bitmap is drawn in the same space differs from both by 1 level in 7 pixels
  (0.003 %, all inside group boxes); drawing the groups through a window-sized scratch bitmap in that space (EPxw)
  gives **0 differing pixels**, also over the backdrop. In an sRGB window the same holds with an sRGB base (EP: 7 px;
  EPx: 0).
- **What Deskset ships is B+kept, not B drawn in full**, and the spike's B is its own reimplementation of Deskset's
  drawing, not Deskset's renderer. `q1` builds every window directly at tick 7 and draws it once, so its B has no kept
  pictures. `q1-stepped.json` (added after review) steps every window from tick 0 to 7, a redraw per tick, so B+kept
  has made and copied its pictures (4 copied, 13 of 24 elements drawn directly in the captured frame): **E1, EPxw, C1
  and B drawn in full all differ from B+kept by 1 level in 1,393 pixels (0.68 %), EPw and CPw in 1,400**; B+kept drawn
  once (no pictures yet) equals B. So the partition equals B drawn in full, and differs from what Deskset shows today
  by max 1 in about 0.7 % of the pixels (0.4–0.7 % in the cost runs' own check, `keptPicturesVsFullDrawing`), all of it
  B+kept's rounding when it copies pictures. Real Deskset was not captured next to the spike.
- The 7 pixels come from CoreGraphics itself: drawing the same curved path moved by whole device pixels does not give
  identical pixels (question 5). The scratch bitmap draws every element at its window position, so nothing moves.
- **Mixing color spaces costs 48 % of the pixels**: an sRGB base bitmap copied into E contexts that are in the
  display's space is converted by CoreGraphics while the base tiles are converted by the window server; the two
  conversions round differently (max 1 in 48 % of the pixels, over the backdrop max 2 in 48.11 %). EPx in the default
  window is worse (max 9, 56.58 %): its sRGB scratch bitmap carries sRGB pixels into contexts in the display space.
- **What an sRGB window changes against today**: anything rendered in 8-bit sRGB (E1, EP, D1 or B in an sRGB window)
  changes about 54 % of B's pixels, **by 1–2 levels in 99.9 % of them** (106,883 by 1, 2,705 by 2; about half the
  pixels by ±2, as the draft estimated from the review), with 96 outliers (0.05 %) of 3–9 levels (50 by 3, 44 by 4–7,
  2 by 8–9); outside the group boxes (the panel alone) at most 1; over the backdrop max 9 in 65.04 %. For scale, the
  change from A to B that main already shipped touched 84 % of the pixels (below).
- **A vs B and E**: A drawn once is rendered in the window's color space at a higher precision than an 8-bit bitmap
  (question 4: an `RGBA16Float` E layer equals it exactly), so B and E1 differ from A drawn once by up to 6 levels in
  84 % of the pixels (167,947 by 1, 3,896 by 2, 40 by 3–6; the panel alone at most 2). 8-bit sRGB differs from it by
  up to 10 in 87 %. In an sRGB window A, B, E1 and D1 are identical.
- **A drawn once is not what the old Deskset showed for skins that update.** An A skin that keeps redrawing moves onto
  Core Animation's accelerated path (`memtrace`), and it rasterizes differently: in `q1-stepped.json`, A after 7 + 10
  redraws, and A after 2 s of redraws at 60 Hz (identical to each other), differ from A drawn once in 15,782 pixels
  (7.7 %): by 1 in most, but 666 pixels by 8 or more and up to 103 (edges of the line graph, the pill and the icon,
  and a dither-like pattern over the panel, `crops/q1s-diff-full-A-redrawn-vs-A-drawn-once.png`). The `RGBA16Float`
  E layer equals only A drawn once. **B, B+kept and E1 differ from A as it looked when updating by up to 102 levels in
  85 % of the pixels** (166,121 by 1, 4,797 by 2, 2,069 by 3 or more). So "A = RGBA16Float E" and "A→B: max 6 in
  84 %" describe static A only; the A→B note in `docs/compat/` has to use the updating A.
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

### After review: memory (`sysmem/`; bitmap bytes from `cost/`, `cost-b/`)

The comparisons of memory below `phys_footprint` (in "As measured before review") rank the ways by how the kernel
attributes pages, not by what they hold (see Conditions). Two views that count every buffer:

**Bitmap bytes, each buffer once** (uncompressed, per widget; from the runs' own counts). For E the layers' backing
stores plus the runtime's own bitmaps, the base counted once (the tiles show it); for B, C and D the runtime's own
bitmaps or surfaces, whose images the layers show:

| way | System widget (260 × 196 pt) | design skin (360 pt) | visualizer |
|---|---|---|---|
| E1 (one layer) | 1.55 | 3.96 | 1.43 |
| **EPw** (partition, E) | **1.58** | **3.11** | 0.77 |
| EPxw (partition through a scratch bitmap) | 2.32 | 5.09 | 1.24 |
| C1 (one layer) | 1.55 | 3.96 | 0.95 |
| **CPw** (partition, C) | **1.73** | **3.77** | 1.06 |
| CPxw | 2.51 | 5.75 | 1.53 |
| D1 / DP (sRGB IOSurfaces, first campaign) | 1.66 / 2.89 | 4.06 / 5.40 | 1.00 / 2.05 |
| B drawn in full / **B+kept** (today) | 1.55 / **4.67** | 3.96 / **9.89** | 0.95 / 1.43 |

By bytes **C holds more than E**: +0.15 MB per System widget, +0.65 MB per design skin (the partition's groups have
two bitmaps each in C, while CA gives a second buffer only to layers that keep changing). This reverses the
phys_footprint reading ("C 2.19 vs E 2.70 MB for the design skin"). These counts leave out copies made behind the
scenes (a C bitmap redrawn while the window server still holds its previous image is copied on write), which the
next view sees.

<!-- sysmem table -->

### After review: CPU (`cost-d/`, `wspair/`, `frames60/`, `schedpair/`)

**One interleaved batch** (`cost-d/`): every combination below once per round, three rounds, in its own folder;
each run records the proc_pid_rusage v6 counters of its on phases (instructions retired, cycles, the share of CPU
time on performance cores, average clock) and the skin thread's CPU time per update. This Mac's load stayed high
(1-minute load 5.6–43, 50 of 66 runs above 8): every CPU number here is provisional in absolute terms; the batch is
for comparisons within it, and the counters show what the time went into.

| scenario | way | process % of one core, median (min–max) | instructions M/s | cycles per instruction | P-core share | wakeups/s |
|---|---|---|---|---|---|---|
| 60 Hz | A | 8.35 (7.91–8.82) | 824 | 0.35 | 0.96 | 358 |
| 60 Hz | B drawn in full | 7.73 (7.62–9.55) | 1,023 | 0.29 | 1.00 | 75 |
| 60 Hz | **B+kept** (today) | **3.90** (3.89–4.76) | 413 | 0.36 | 0.99 | 78 |
| 60 Hz | E1 | 6.87 (6.64–8.01) | 1,019 | 0.25 | 1.00 | 64 |
| 60 Hz | **EPw** | **5.41** (5.39–7.02) | 594 | 0.35 | 0.99 | 62 |
| 60 Hz | C1 | 7.43 (6.97–8.01) | 1,046 | 0.26 | 1.00 | 62 |
| 60 Hz | **CPw** | **4.21** (4.17–4.84) | 517 | 0.31 | 1.00 | 62 |
| 10 widgets, 1 s | A | 0.76 (0.75–0.87) | 50 | 0.56 | 0.99 | 8.1 |
| 10 widgets | **B+kept**, timers aligned | **0.87** (0.81–0.96) | 109 | 0.29 | 0.99 | 3.7 |
| 10 widgets | B+kept, timers spread over the second | 1.19 (1.12–1.34) | 110 | 0.41 | 0.99 | 12.7 |
| 10 widgets | E1, 10 threads, aligned | 2.09 (2.02–2.11) | 307 | 0.25 | 0.96 | 5.4 |
| 10 widgets | E1, one thread, aligned | 1.55 (1.47–1.70) | 305 | 0.19 | 0.99 | 6.6 |
| 10 widgets | C1, 10 threads, aligned | 2.19 (2.10–2.26) | 309 | 0.26 | 0.94 | 3.3 |
| 10 widgets | **EPw, 10 threads, aligned** | **1.61** (1.50–1.65) | 95 | **0.60** | 0.93 | 5.3 |
| 10 widgets | EPw, 10 threads, spread | 1.21 (1.19–1.28) | 96 | 0.48 | 0.99 | 15.3 |
| 10 widgets | EPw, one thread, aligned | 0.78 (0.72–0.82) | 88 | 0.32 | 0.99 | 5.8 |
| 10 widgets | EPw, one thread, spread | 1.17 (1.16–1.37) | 95 | 0.47 | 1.00 | 14.7 |
| 10 widgets | **EPw, one thread, coalesced** (one timer, one commit) | **0.71** (0.69–0.92) | 86 | 0.32 | 0.99 | 5.3 |
| 10 widgets | CPw, 10 threads, aligned | 1.32 (1.29–1.38) | 92 | 0.53 | 0.97 | 3.2 |
| 10 widgets | CPw, 10 threads, spread | 0.97 (0.96–1.17) | 91 | 0.41 | 1.00 | 12.0 |
| 10 widgets | CPw, one thread, aligned | 0.71 (0.67–0.87) | 85 | 0.32 | 0.99 | 3.3 |
| 10 widgets | **CPw, one thread, coalesced** | **0.69** (0.67–0.90) | 88 | 0.30 | 0.99 | 3.5 |

What the counters show:

- **The scheduling changes the cycles, not the work.** For each way the instructions per second stay within about
  10 % across all its scheduling variants (EPw 86–96 M/s), and nearly all CPU time is on performance cores (0.93–1.00)
  at 3.4–3.8 GHz, so neither efficiency cores nor a low clock explain the differences. What changes is the cycles
  per instruction: EPw needs 0.32 cycles per instruction when the 10 updates run back to back on one thread, 0.47–0.48
  when they are spread over the second (on one thread or ten), and 0.60 when ten threads run them at the same moment
  (with 18 ms per second spent runnable, waiting for a core, against 8 on one thread). Cold caches for each isolated
  update, and contention when ten run at once, are the likely causes; the per-update thread CPU time follows (EPw:
  1,219 µs of CPU per update on ten aligned threads, 737 µs spread, 483 µs on one thread; wall clock 1,450 / 738 /
  483 µs).
- **It is the timing of the updates, not the number of threads.** One thread with spread timers costs as much as ten
  threads with spread timers (1.17 vs 1.21 %). **Today's B+kept pays the same when its timers are spread** (0.87 %
  aligned, 1.19 % spread): with the unaligned timers real skins have, the partition costs what B+kept costs (EPw
  1.17–1.21 %) or less (CPw 0.97 %). The earlier "one shared thread 0.62 % vs B+kept 0.75 %" compared aligned with
  aligned; the "ten threads spread 1.03 % and 13 wakeups" compared spread E with aligned B+kept.
- **Coalescing is what saves**: one timer for all 10 widgets on one thread, one transaction and one flush: EPw 0.71 %,
  CPw 0.69 %, below today's B+kept aligned (0.87 %), with 3.5–5.3 wakeups per second.
- **Wakeups**: DESK-DESIGN's target is "10 widgets updating every second, ≤ 12 wakeups per second", so it is per
  process. Spread timers cost 12.0–15.3 wakeups per second in every way, B+kept included (12.7): no engine meets it
  with 10 unaligned 1 Hz skins; it needs updates that fall due together to be run together.
- **At 60 Hz** the interleaved batch agrees with the paired step: E (EPw) 5.41 % against B+kept 3.90 % (+1.5 points in
  this process alone, over the plan's 1-point rule), C (CPw) 4.21 % (+0.3). CPw draws the same pixels as EPw with
  13 % fewer instructions (517 vs 594 M/s).
- 60 Hz frames in this batch (5 s each, after the phases): rounds below 298 / 300 under this load for A (291), B (295,
  296), B+kept (297, 296) and EPw (297); none for CPw, C1 and E1. Longest freezes 19–56 ms. `frames60/` (10 s,
  10 rounds) is the cleaner check; the one long freeze there is EPw's 170 ms commit stall.

**The same in pairs within one process** (`schedpair/`, 2 processes × 8 cycles; three sets of 10 System widgets on
screen, EPw on 10 threads, EPw on one shared thread, B+kept on the main thread; one way runs at a time for 5 s, an idle
phase in every cycle; mean ± standard error over the 16 cycles, increase over idle; load 7–14):

| way (10 widgets, 1 s) | process % of one core | instructions M/s | cycles M/s | cycles per instruction | wakeups/s |
|---|---|---|---|---|---|
| EPw, 10 threads, aligned | 1.62 ± 0.02 | 101 | 60.3 | 0.60 | 2.5 |
| EPw, 10 threads, spread | 1.06 ± 0.01 | 93 | 40.4 | 0.44 | 11.7 |
| EPw, one thread, aligned | 0.67 ± 0.01 | 88 | 25.5 | 0.29 | 2.7 |
| EPw, one thread, spread | 1.05 ± 0.01 | 92 | 40.1 | 0.44 | 11.3 |
| **EPw, one thread, coalesced** | **0.64 ± 0.01** | 86 | 24.5 | 0.29 | 2.7 |
| B+kept, aligned | 0.74 ± 0.03 | 116 | 28.3 | 0.24 | 1.1 |
| B+kept, spread | 1.13 ± 0.03 | 118 | 43.2 | 0.37 | 10.3 |

Same order, much tighter: spreading the timers costs +0.4 points whether the widgets share a thread or not, and costs
B+kept the same +0.4; ten threads updating at the same moment cost +1.0 point over one thread; coalescing the updates
on one thread is the cheapest way here, below B+kept with aligned timers.


### As measured before review

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
- Rounds: every combination 3 times (the cost and wscpu tables), WindowServer memory 5 times. Tables give the median
  and (min–max). Corrected after review: `cost-b` itself was interleaved (10:01–10:48), but the C step (C1, CPw, CPxw
  and a rerun of B+kept at 60 Hz) and the thread step ran later as separate batches (committed 13:02 and 13:15–13:27)
  under other loads, and wrote into the same folder: their comparisons with E are **not** interleaved, and the B+kept
  rerun overwrote the files that had been interleaved with EPw (originally 4.17 / 3.84 / 3.77 %, now 3.90 / 4.08 /
  3.98 %). The batch added after review (`cost-d/`) interleaves all of them and overwrites nothing.

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
- **B's own bitmaps are not in its footprint while shown**: two 0.78 MB bitmaps per System widget, yet +0.24 MB per
  widget. That is how phys_footprint attributes pages whose image the window server holds (see Conditions), not a
  saving: the same pages are back in the footprint while the windows are ordered out. B+kept's pictures stay in it
  (they are read every frame when copied): +3.38 MB per System widget (own bitmaps 4.67 MB: the two bitmaps and four
  pictures), +6.33 MB for the design skin (9.89 MB: two bitmaps and three pictures of 1.98 MB).
- **E layers** are charged as "CoreAnimation" (backing stores; CA gives layers that keep changing a second buffer, and
  marks one of them volatile) and the partition's base bitmap and base crops as "CG raster data". EPw: 2.17 MB per
  System widget (partition minimum, window + group boxes: 1.25 MB), 2.70 MB for the design skin (3.03 MB in its one
  round at memory pressure level 1). These too are lower bounds: the base bitmap is itself an image made from a
  bitmap context, and only part of it is charged ("CG raster data" +1.06 MB for a 1.98 MB base in the design skin).
  The scratch bitmap (EPxw) adds about one window bitmap: 3.44 MB and 5.27 MB.
- **C**'s bitmaps are attributed like B's: C1 +0.88 MB per System widget by phys_footprint (own bitmaps 1.55 MB),
  +0.25 MB for the design skin. The partition CPw keeps the base bitmap and two bitmaps per group (own 1.73 MB per
  System widget): +2.82 MB (one skin thread: 2.46 MB), +2.19 MB for the design skin. These are lower bounds, not
  costs; the comparison with E is in "After review: memory" above.
- **D** (first campaign) is charged in full for its IOSurfaces (up to 3 per layer): 2.35 / 3.49 MB per System widget
  (D1 / DP), 4.42 / 5.69 MB for the design skin.
- Hiding the windows (ordered out for 5 s in `memtrace-b`) raised every mode's footprint while hidden (EPw +2 MB,
  E1 +8 MB, B +15 MB for 10 widgets) until they were shown again. Corrected after review: this is the same pages
  being attributed to this process again once the window server lets go of them (B: +15.05 MB = two 0.78 MB bitmaps
  × 10 widgets; design B +3.9 MB = two 1.98 MB bitmaps), not memory the spike failed to release. (The spike does not
  release contents while hidden; the plan does, and M1 has to measure that release with a method that sees these
  pages.)

**What the CPU numbers mean**

- **With one thread per widget and all widgets updating at the same moment** (every run in the tables unless marked),
  10 System widgets updating every second cost: the partitions 1.13 % (DP) – 1.24 % (CPw) – 1.45–1.51 % (EP / EPw) of
  one core, the scratch variants 1.72–1.91 %, one layer (E1, C1, D1) and B drawn in full 1.56–2.08 %; today's B+kept
  0.75 % and A 0.62–0.78 % (both on the main thread). At 60 Hz: B+kept 3.98 %, CPw 4.07 %, DP 4.18 %, EPw 5.57 %,
  E1 6.49 %, B 7.73 %, A 8.11 %. The design skin is cheap in every mode that redraws only what changed (0.09–0.15 %).
- **Most of the partition's cost in the 10-widget runs comes from how the updates are timed, not from the layers.**
  The same 10 widgets on **one shared skin thread**, updating one after another: EPw 0.62 %, CPw 0.58 % (below
  B+kept), E1 1.41 %, C1 1.50 %. On ten threads with their updates **spread over the second** instead of at the same
  moment: EPw 1.03 %, E1 1.85 %. Corrected after review: these runs were separate batches (not interleaved with the
  others), B+kept and one thread were measured only with aligned timers, and CPU time was read as work. The
  interleaved batch with counters ("After review: CPU" above) separates the factors: the instructions stay the same,
  the cycles per instruction change; spreading the timers costs the same on one thread as on ten, and B+kept pays it
  too; coalescing the updates is what saves.
- One layer drawing the whole skin shows the same effect: 2,014–2,023 µs per System widget for E1 and C1 on ten
  simultaneous threads, 1,235–1,279 µs on one thread, 1,384 µs for B on the main thread (the same pixels into the same
  kind of bitmap).
- The partition otherwise pays per layer: the commit of 19 group layers and 38 tiles (51–62 µs on one thread) against
  22–31 µs for one layer; C's commit is a little dearer than E's, its drawing a little cheaper (60 Hz: 482 + 134 µs
  vs 636 + 189 µs per frame).
- Wakeups (interrupt wakeups of this process per second, all widgets together): 1.4–4.6 for 10 widgets updating at the
  same moment or on one thread (EP16: 6.5), 12.5–13.3 when their updates are spread over the second (each widget wakes
  its own thread), 1.6–1.8 for B, 5.7–6.8 for A; 60–80 at 60 Hz (A: 230–340).
- **WindowServer's CPU from the on / off rounds (`wscpu/`, `wscpu-b/`) cannot be resolved below about 2 % of a core**
  (corrected after review; it said "no measurable change, target met"). The per-run means are consistent within a
  campaign, so the spread is not only noise: the main-thread ways read −4.1 to −5.5 % at 60 Hz (WindowServer cannot
  get cheaper when we update), so the off-phase baseline itself is biased by 1–10 % depending on the way. With the
  three runs as the independent units (the 30 pairs are not independent), 10 EPw widgets read −0.15 ± 0.50 % (95 %
  interval about ±2.2 % with 2 degrees of freedom) and 10 E1 widgets have a run at −2.65 %; "< 1 %" cannot be shown.
  The first campaign's partitions in sRGB windows read +2.39 / +0.80 / +2.03 (EP) and +2.10 / +1.84 / +2.44 (DP) per
  run at 60 Hz against −0.66 / +0.13 / −0.52 (E1) and −0.43 / +0.33 / +0.39 (D1) in the same batch.
- **Paired instead (`wspair/`, added after review)**: every way has its own visualizer window on screen the whole time
  over one opaque backdrop, one updates at 60 Hz at a time, and an idle phase (nothing updates) is in every cycle; 10
  shuffled cycles per process, 3 processes, 4 s phases. The cycles are the units (30), all under the same background.
  The load was high (1-minute load up to 24, 211 of 300 phases above 8), which the pairing cancels only in part:

  | 60 Hz, one visualizer | WindowServer over idle | this process over idle | sum |
  |---|---|---|---|
  | B+kept (today) | −2.02 ± 0.72 | 4.02 ± 0.04 | 2.01 ± 0.72 |
  | B drawn in full | −2.81 ± 0.96 | 7.79 ± 0.05 | 4.97 ± 0.95 |
  | A | −2.99 ± 0.87 | 7.95 ± 0.10 | 4.96 ± 0.86 |
  | E1 (default window) | +0.07 ± 0.29 | 6.79 ± 0.06 | 6.85 ± 0.28 |
  | EPw | +0.65 ± 0.33 | 5.66 ± 0.07 | 6.31 ± 0.33 |
  | C1 | −0.07 ± 0.32 | 7.38 ± 0.09 | 7.31 ± 0.31 |
  | CPw | +0.78 ± 0.37 | 4.26 ± 0.04 | 5.04 ± 0.36 |
  | E1, sRGB window | +0.39 ± 0.64 | 6.46 ± 0.04 | 6.85 ± 0.64 |
  | EP, sRGB window | +1.06 ± 0.32 | 5.43 ± 0.07 | 6.49 ± 0.33 |

  | difference (same cycle) | WindowServer | this process | sum | per process round (sum) |
  |---|---|---|---|---|
  | **CPw − EPw** (C vs E) | +0.13 ± 0.25 | −1.40 ± 0.07 | **−1.27 ± 0.26** | −0.91, −1.22, −1.69 |
  | **EPw − B+kept** (E vs today) | +2.67 ± 0.64 | **+1.64 ± 0.07** | **+4.30 ± 0.65** | 4.25, 3.81, 4.86 |
  | **CPw − B+kept** (C vs today) | +2.80 ± 0.66 | **+0.23 ± 0.05** | +3.03 ± 0.67 | 3.34, 2.59, 3.16 |
  | EPw − E1 | +0.59 ± 0.33 | −1.13 ± 0.07 | −0.54 ± 0.33 | |
  | E1 − B (same pixels, skin thread vs main thread) | +2.88 ± 0.91 | −1.00 ± 0.06 | +1.88 ± 0.90 | |
  | EP − E1, both in sRGB windows | +0.67 ± 0.64 | −1.03 ± 0.07 | −0.36 ± 0.66 | |
  | EP in an sRGB window − EPw | +0.40 ± 0.31 | −0.23 ± 0.08 | +0.18 ± 0.33 | |

  (mean ± standard error over the 30 cycles, % of one core.) What this shows:
  - **C does not move work to WindowServer**: CPw and EPw cost WindowServer the same (+0.13 ± 0.25), and C costs this
    process 1.4 points less, so C is cheaper than E at 60 Hz in total by about 1.3 points.
  - **Against today's B+kept both partitions cost more at 60 Hz**: E +1.6 points in this process alone (over the
    plan's 1-point rule) and C +0.2; with WindowServer, E +4.3 and C +3.0. Part of that WindowServer difference is the
    way the main-thread modes read: A, B and B+kept all read 2–3 points *below* the idle phase (B and E1 draw the same
    pixels into one layer, yet WindowServer reads 2.9 points more when a skin thread commits them). That is either
    real (main-thread commits reach the window server in a cheaper way) or an artifact of how its time is read.
    A second paired run with billed system time (`wspair-billed/`, 8 cycles, A / B / B+kept / E1 / EPw / CPw) rules
    out the obvious artifact: time other processes spent for this one and billed to it is *smaller* for the
    main-thread ways (3.4–5.6 ms per second) than for the partitions (EPw 9.7, CPw 10.9 ms per second, about 0.4–0.5
    points of a core more than B+kept). The same run repeats the rest: CPw − EPw −1.6 ± 0.5 points in total
    (WindowServer −0.4 ± 0.5), EPw − B+kept +1.6 ± 0.05 in this process, +6.3 ± 1.3 with WindowServer. The main-thread
    ways' low WindowServer readings stay unexplained, so **the sums against B+kept are an upper bound and the
    process-only differences a lower bound**; the billed time says the partitions do make other processes work about
    half a point more than B+kept.
  - The first campaign's "+2 % for partitions in sRGB windows" does not reproduce when paired: EP in an sRGB window
    costs WindowServer 0.40 ± 0.31 more than EPw, 0.67 ± 0.64 more than E1 in an sRGB window.
  - The GPU's utilization (whole system) rose by 1–2 points for every way, with no difference between ways that
    stands out of its noise (± 0.6–0.9).
  - With 10 widgets updating every second the differences are below what this screen's WindowServer resolves; the
    paired step was run at 60 Hz only.
- 60 Hz frames (corrected after review): the medians were 298–300 of 300 committed frames in 5 s, but **two rounds
  failed the M1 bar of 298 / 300**: EPw round 3 (291 of 300, one frame on screen for 91.6 ms, load 7.77 at the end:
  not provisional) and CPxw round 3 (294, 71.1 ms). Commit intervals p50 16.67 ms, p99 17.1–21.6 ms.
- **Rerun after review (`frames60/`)**: EPw, CPw and B+kept, 10 rounds each, interleaved, 10 s of read-back per round
  (about 600 frames), the skin thread's commit times logged around the longest freeze. The load stayed high (6.6–26 at
  the end of the rounds). B+kept: 298.5–300 per 300 in every round, longest freeze 20–39 ms. CPw: 299–299.5 in every
  round, 23–33 ms. **EPw: 9 rounds at 299–300, one at 296.9 (round 2: 573 of 579 frames, one frame on screen for
  170 ms).** The log shows where: drawing stayed at 0.6–0.7 ms, but the skin thread's `CATransaction.commit()` plus
  `flush()` took 5.9 ms, then **92 ms, then 142 ms** for three frames in a row, so the skin thread itself was blocked in
  the commit and committed only 579 frames in 10 s. So the stall recurs (2 of the 13 EPw rounds so far, none of the
  13 CPw and 13 B+kept rounds at 60 Hz fell below 298), and it is the commit, not the drawing and not the main thread.
  One plausible cause, not verified: an E layer's backing store has two buffers, and a commit can wait until the
  window server lets go of the one to be reused; C hands over a new image every frame and never waits for a buffer.
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

(CPU numbers from runs with a load above 8 are provisional, see the tables. Corrected after review: the two campaigns
do **not** agree closely enough to compare across them. The bridge moved by up to 0.87 points (12 %) at 60 Hz: sixty-A
7.24 → 8.11 %, sixty-E1 6.20 → 6.49 %, and E1 was not even the same configuration (an sRGB window on 09-27, the
default window on 09-28). So modes are not ranked across campaigns; D's 1.13 / 4.18 % compare only with the first
campaign's E and A.)

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

Which combination brings E closest to A and to B (System widget, one E layer; A and B in the default window; A drawn
once and B drawn in full, see question 1 for B+kept and for A while updating):

| E layer | vs A (drawn once) | vs B (drawn in full) |
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
| the review's 64.4 / 57.2 / 59.9 % (270° / 180° / 225°, box not recorded) | **the effect is reproduced, the review's figures are not** (`q5-review-search*.json`): on a 1 pt grid, 298 of 27,531 positions give 64.4 % at 270° and 15 give 59.9 % at 225°, none gives 57.2 % at 180°, and none gives all three (the closest is 2.0 points off); on a 0.5 pt grid (109,461 positions) 814 / 0 / 112, none all three (closest 0.75 points off). About 1 % of the positions land on any 0.1 % bin, so hitting 64.4 % somewhere proves nothing about the review's box |
| box at the panel's top left (100 × 30, and 260 × 100) | **0** |
| the whole panel moved 10 pt (translation only) | **0** |
| solid translucent rounded panel, cut | **0** |
| same bitmap, clipped to the box (rectangle or even-odd) | max 1, 70.83 % (as cutting) |
| same bitmap, even-odd hole around the box (compared outside it) | **0** |
| **whole-window base bitmap, box copied out in whole pixels** (`.copy`, no interpolation) | **0** |

The gradient's pixels depend on where the clip's bounding box starts: a box that starts at the panel's top left, or a
hole that leaves the bounding box unchanged, gives 0; any other start changes about two thirds of the pixels by 1
(median 67.9 %). That is the effect the review described; its exact box and figures were not identified.

Whole partitions composed offline (base bitmap + each group's bitmap copied in) vs one bitmap, worst of ticks 0, 1, 7,
60, 61 (`q5.json`, 2×; `q5-partitions/` at 1× and 2×, as arm64 and as an x86_64 build under Rosetta, whose
CoreGraphics output is the Intel runner's, question 8):

| widget | groups / tiles | partition vs one bitmap | where (summed over the 5 ticks) | naive (panel redrawn per group, clipped) | scratch bitmap |
|---|---|---|---|---|---|
| System | 19 / 38 | max 1, 16 px (0.008 %) | CPU graph + fill 45 px, 2 core bars 1 px each | max 1, 33.66 % | **0** |
| design | 8 / 25 | max 1, 10 px (0.002 %) | ring gauge + its text 28 px | max 1, 26.50 % | **0** |
| visualizer | 34 / 22 | max 1, 1 px (0.001 %) | one gradient bar | max 1, 26.85 % | **0** |

| widget | arm64 1× | arm64 2× | x86_64 1× | x86_64 2× |
|---|---|---|---|---|
| System | max 1, 2 px | max 1, 16 px | max 1, 2 px | max 1, 18 px |
| design | max 1, 2 px | max 1, 10 px | max 1, 2 px | max 1, 10 px |
| visualizer | 0 | max 1, 1 px | 0 | max 1, 1 px |

The translation noise is of the same size on both architectures and at both scales (at most 1 level, ≤ 0.009 % of the
pixels); the scratch bitmap gives 0 in all twelve cases.

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

- Corrected after review: in the sRGB window the table's `phys_footprint` column is blind (one image, 61 tiles and
  8 separate copies all within 0.5 MB of the empty window), and `top`'s WindowServer column is blind too (+12–13 MB
  for one image and for 8 copies of it: it follows the window's surface, not the contents). So this table showed
  "counted once" only in the default window, through CA's converted copy.
- **Measured again with a view that sees the pages** (`footprint --vmObjectDirty` of this process, the same
  random-pixel image, `sysmem/control-*.json`, median of 3 open steps):

  | window | empty | one layer | **61 tiles sharing it** | 61 `CGImage.cropping` tiles | 8 separate copies |
  |---|---|---|---|---|---|
  | sRGB (contents already in the window's space: what the plan does) | +0.5 MB | +10.2 MB | **+10.2 MB** | +13.3 MB | +78.7 MB |
  | default (sRGB contents, CA converts them) | +0.5 MB | +20.0 MB | **+20.0 MB** | +20.2 MB | +156.9 MB |

  **Counted once, in both windows**: 61 tiles sharing one image cost exactly one image, 8 copies cost 8 (78.7 MB for
  8 × 9.77). In the default window CA's converted 8-byte-per-pixel copy is made once for all tiles sharing an image
  and once per separate image (8 × 19.6 MB). Cropped images hold a little more (+3 MB here). What the window server
  holds for them was not measured.
- An IOSurface the process wrote is charged to it in any view (+9.8 MB).

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
| `g2-tiles` | the same widget partitioned: 15 base tiles sharing one base image through `contentsRect`, 5 group bitmaps that are **crops of `g2-single`'s bitmap** (the scratch-bitmap way) | 20 |
| `g2-e` | the same with group layers that copy those crops in `draw(in:)` (E; their context was sRGB, 8 bpc, everywhere) | 20 |
| `g2-groups` (added after review) | the partition **as the plan draws it** (§6.2 of the plan): each group's bitmap is the base's crop copied in with `.copy`, then the group's elements drawn into the group's own bitmap, moved by whole pixels | 20 |
| `g2-e-drawn` (added after review) | the same drawing done in each group layer's `draw(in:)` (E) | 20 |

It checks `image` and `cg` and `g2-single` against their source bytes and the partitions against `g2-single`, and (on
the CPU, without Core Animation) the partition composed from the plan-style group bitmaps against `g2-single`'s source,
compares every scene with this Mac's run (`ci-probe/local-arm64/`, the pixels deflate-compressed), and times the
partitioned widget: three rounds of 20 renders each, in four ways, with the texture overwritten with garbage before
every render and every read-back required to hash like the first. Each machine ran it three times: this Mac
natively three times and once as an x86_64 build under Rosetta (`local-*.json`), each runner three times (workflow run
36383643743, attempts 1–3, `ci-36383643743-attempt*.json`). The scenes added after review (`g2-groups`, `g2-e-drawn`)
ran here natively and under Rosetta (`local-arm64-plan-groups.json`, `local-x86_64-rosetta-plan-groups.json`; their
pixels are in `local-arm64/scenes/`) but **not yet on the runners**: the workflow runs them on the next push of this
branch. (Run 36383370736, `ci-36383370736-*.json`, was the probe before the read-back fix below.)

Load: the rule "a 1-minute load above 8 is provisional" was set for this 14-core Mac (0.57 per core) and does not
transfer to 3- and 4-core virtual machines. Per core, a round is provisional here when the 1-minute load divided by
the cores exceeds 0.6. The load average also updates only every 5 s, so a round of 20 renders (under 1 s) reads the
same value before and after. By that rule **every timed CI round except the Intel runner's attempt 2 is
provisional**: `macos-26` (3 cores) 3.74, 7.26, 5.1 (1.2–2.4 per core) in attempts 1–3; `macos-26-intel` (4 cores)
6.39 (1.6 per core; 5-minute load 32), 1.59 (0.4) and 4.73 (1.2; 5-minute 13). This Mac's native runs had 4.7–4.8
(0.34 per core). The pixel results do not depend on the load; the timings below do.

| | this Mac | `macos-26` | `macos-26-intel` |
|---|---|---|---|
| machine | Mac16,8, Apple M4 Pro, 14 cores | VirtualMac2,1, "Apple M1 (Virtual)", 3 cores, 7 GB | a virtual machine reporting Macmini6,2, Intel Core i7-8700B, 4 cores, 14 GB |
| macOS | 26.5.2 (25F84) | 26.6.2 (25G83) | 26.6.1 (25G76) |
| `MTLCreateSystemDefaultDevice()` | Apple M4 Pro | **Apple Paravirtual device** (unified memory, family `mac2` only, 4.8 GB working set) | **Apple Paravirtual device** (no unified memory, no GPU family, 1 GB working set) |
| display | built-in XDR, 1512 × 982 pt | 1024 × 768 | 1920 × 1080 |

**Both runners can composite offscreen.** Every scene rendered on both, the read-backs are not the bytes written
before the render, and every scene hashes the same in all three runs of a runner (three separate virtual machines).
Within a run, the partitions made of **copied** pixels are exact on both runners. That holds by construction (their
group pixels are crops of the one-layer bitmap), so it shows that Core Animation composites copied bitmap pixels
exactly, not that a partition drawn the plan's way matches one layer:

| check (1× and 2×) | this Mac | `macos-26` | `macos-26-intel` |
|---|---|---|---|
| `image` == its source; `cg`, `g2-single` == their source bitmaps | 0 | 0 | 0 |
| `g2-tiles` == `g2-single` | 0 | 0 | 0 |
| `g2-e` == `g2-single` | 0 | 0 | 0 |
| the G2 trees rendered a second time, and `g2-tiles` 240 more times per run (4 ways × 3 rounds × 20) | same bytes | same bytes | same bytes |
| `vector` rendered a second time | same bytes | same bytes | **max 1 in 301 px (0.098 %) at 2×** in all three runs (the second render differs from the first the same way each time); at 1× 0, 4 and 4 px |

The partition drawn the plan's way (after review; this Mac, arm64 and x86_64 under Rosetta, whose CoreGraphics output
is byte for byte the Intel runner's for `cg` and the G2 scenes):

| check | arm64 1× | arm64 2× | x86_64 (Rosetta) 1× | x86_64 (Rosetta) 2× |
|---|---|---|---|---|
| `g2-groups` == `g2-single` | max 1, 2 px (0.003 %) | max 1, 3 px (0.001 %) | max 1, 3 px (0.004 %) | max 2, 3 px (0.001 %) |
| `g2-e-drawn` == `g2-single` | max 1, 2 px | max 1, 3 px | max 1, 3 px | max 2, 3 px |
| the same partition composed on the CPU == `g2-single`'s source | max 1, 2 px | max 1, 3 px | max 1, 3 px | max 2, 3 px |
| `g2-e-drawn` == `g2-groups`; `g2-groups` == the CPU composition | 0 | 0 | 0 | 0 |

Every difference is CoreGraphics' translation noise (the CPU composition has exactly the same pixels); Core Animation
adds nothing. On x86_64 one pixel differs by 2 at 2×, still inside G2's tolerance (≤ 2, ≤ 0.1 %). The runners should
show the same when the workflow runs again; until then the plan-style check on the runners is unmeasured.

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
| a new tree each time (built, attached, committed, rendered), 2× | 0.49 ms (0.44–0.58) | **3.39 ms** (1.52–4.19)* | **7.03 ms** (6.45–11.97)* | 1.03 ms |
| a new texture and renderer each time, 2× | 0.88 ms (0.84–0.94) | 21.7 ms (12.0–22.9) | 9.26 ms (8.53–14.81) | 1.85 ms |
| read-back and flip, 2× | 0.44 ms | 0.72 ms | 0.26 ms | 5.06 ms |
| first render in the process | 5–8 ms | 111–209 ms | 139–724 ms | 57 ms |

(`*`: 8 of the 9 CI rounds per runner are provisional by the per-core rule above; the only calm round set, the Intel
runner's attempt 2, gave 6.45–6.65 ms.)

The plan budgets about 10,000 renders for the G2 matrix at 5–20 ms each. With one renderer and texture per size and a
new tree per render, the round medians put one render with its read-back at 2.2–4.9 ms on `macos-26` and 6.7–12.2 ms
on `macos-26-intel` (less at 1×): **about 20–50 s and 65–125 s of `CARenderer` time**, far inside the 10 and 20
minute caps even at the slow end. A new renderer per render would cost about 22 ms on `macos-26` (almost 4 minutes).
Building the skins' scenes and bitmaps, which the probe does not measure, will be the larger part.

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

### A window's color space changing under a partition (`cschange/program-*.json`, added after review)

The plan keeps the window's own color space and draws the base bitmap in it; the review asked what happens when that
space changes (a window moving to a screen with another profile, or the display's profile changed). No second screen
and no sRGB display were available, and changing the display's profile is a System Settings change the spike does not
make, so this check changes `NSWindow.colorSpace` itself (to sRGB and back) as a stand-in. Two windows, System widget
at tick 7, not updating: the partition with its base in the window's space (EPw) and one E layer (E1); both read back
every 0.25 s; every `draw(in:)` logged with its thread and its context's color space.

| | partition vs one layer, before | right after the change | `draw(in:)` calls after the change |
|---|---|---|---|
| nothing reacts (what CA does by itself) | max 1, 7 px | **max 4 in 106,411 px (52 %)**, for as long as the window stays (4 s here) | **on the main thread**: E1's layer once, **10 of the 19 group layers** (the other 9, small ones, keep old contents), in the new space; the base tiles keep the old base bitmap |
| the runtime reacts (skin thread draws the base again in the new space and redraws every group, one transaction, posted right after the change) | max 1, 7 px | max 1, 7 px (in every capture) | on the skin thread: 1 + 19; none on the main thread |

- So the case the plan's table sent to D is real: a color-space change makes Core Animation call the E layers'
  `draw(in:)` **on the main thread**, which breaks the rule that only the skin thread touches its layers (and runs the
  skin's drawing code on the main thread), and until the runtime draws the base again, groups and base are in
  different spaces (52 % of the pixels off here, like the 48 % of a mixed-space partition in question 1).
- Reacting at once avoided both here, but only because the skin thread's redraw was posted before Core Animation's next
  main-thread pass: with a real screen change the notification (`NSWindow.didChangeScreenProfileNotification`) arrives
  after the change, and the main thread may draw first. Setting `NSWindow.colorSpace` from code posts no notification.
- Layers whose contents the runtime sets itself (C, D) have no `draw(in:)`, so Core Animation cannot redraw them on
  the main thread; their images keep their old color space tag and the window server converts them, so base and
  groups stay consistent until the runtime redraws them.
- Not tested: a real display profile change or a move between screens. `run.sh cschange-person` runs the same check
  for 90 s while a person switches the display's profile (System Settings → Displays → Color profile, for example
  Color LCD → sRGB IEC61966-2.1, and back), once without and once with the reaction.

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
  A color-space change was only simulated from code (side checks); a real one needs a person (`cschange-person`).
- **WindowServer's memory.** `footprint`, `vmmap` and `proc_pid_rusage` need root for WindowServer. `top`'s MEM, the
  GPU's memory in use and system-wide page counts all fail the positive control (8 separate copies of a 9.77 MB image
  must add about 78 MB; see question 3), so no WindowServer memory number here is evidence. To measure it, a person
  would run `sudo footprint -p WindowServer` before and after opening each way's windows.
- The real `NSGlassEffectView` in the glass check is only timed: its tint is not a flat color, so the read-back cannot
  tell whether it lags behind the element (the stand-in view can).
- D with IOSurfaces in the display's color space (it should match B like E does).
- Click-through (steps above).
