# Skin threading: running every skin off the main thread

> Status: design accepted on 2026-09-25 (decisions in §14). Phase 0, the seam and its guard rails, is done
> (2026-09-26, §15); phase 1, thread-safe shared services, is in progress. Every skin still runs on the main thread.
> The spike is in `scripts/spikes/skin-threading/`.
> Clean room: every statement about Rainmeter comes from the public manual (docs.rainmeter.net). Deskset's own
> behaviour comes from its code, and the measurements come from the spike. No Rainmeter source was read.

---

## 1. Summary

Today one thread runs everything: every skin's update (measures, formulas, Lua, bangs, plugin callbacks), all
drawing, the menus, the Manage window and the Skin Studio. One slow thing stalls all the rest:

- a Lua call can take up to 2 seconds (`LuaSupport.secondsLimit`);
- a WebParser `FinishAction` that runs a Lua parser;
- a folder of photos being decoded;
- the Studio rebuilding its inspector.

The spike puts a number on it. With today's model, a 500 ms stall on the main thread freezes every skin for about
510 ms. A 250 ms update in one skin freezes an unrelated 60 Hz skin for about 265 ms (§7.2).

**Proposal.**
- Each skin gets its own thread, called the skin's *executor*. Everything the skin owns lives on it: the `Skin`
  object, its sections, its Lua states, its timers, its plugin callbacks and its drawing.
- The main thread keeps windows, menus, the Manage window and the Studio.
- The two sides talk through messages and an immutable *snapshot* that the skin publishes after each update.
- The main thread may wait for a skin, but only for a bounded time. A skin never waits for the main thread or for
  another skin.

**Frames reach the screen without the main thread.** The skin redraws its own `CALayer` on its executor
(`setNeedsDisplay` + `displayIfNeeded`) and commits it in an explicit `CATransaction` from that thread. In the spike:
- 94–96 new frames per skin reached the screen while the main thread was blocked for 3 × 500 ms (94 expected);
- an unrelated skin kept every frame while its neighbour stalled (64 seen, 63 expected);
- Deskset's own CPU stays at today's level: 5 % of a core for two 60 Hz skins, against 4 % today;
- the commit costs about 20 µs a frame;
- the window server may need a few percent of a core more; phase 2 checks this with real skins (§7.2).

A hop to the main thread would be cheap, but it freezes the skins whenever the main thread is busy. That is the
very problem we are trying to remove.

**Migration.** Six phases. The first user-visible win, "the UI no longer stalls skins", comes after phase 2. It
uses one shared engine thread, and while the Studio has a skin open, that skin runs on the main thread. Phase 3
moves to one thread per skin. The estimate is 26–38 engineer-days without the Studio rework, and 32–48 with it
(§12).

---

## 2. Today

### 2.1 One thread for everything

1. A `Timer` on the main run loop (`SkinController.startTimer`) calls `Skin.update()`.
2. The update runs measures in file order, then meters (update and layout interleaved), then the window size, then
   `OnRefreshAction` / `OnUpdateAction` / `OnWakeAction`.
3. Actions run synchronously as they come.
4. The engine calls `SkinHost.skinNeedsDisplay`. `SkinController` resizes the window, sets `needsDisplay` and
   re-registers tooltip rectangles.
5. On the next display cycle AppKit calls `SkinView.draw(_:)` → `SkinRenderer.draw(skin, in:)`.
6. On macOS 26 the context handed to `draw(_:)` is a *recording* context (a `CGContext` with width 0 and no pixel
   buffer; the layer's contents are `NSViewBackingLayerContents`). The drawing is recorded in Deskset and rasterized
   by the window server. That matters for §7: moving drawing to CPU bitmaps would move rasterizing work into
   Deskset.

The main thread also runs:
- mouse events, which call `Skin.mouseEvent` synchronously and use its result;
- tooltips (`toolTipInfo(at:)`, when AppKit asks) and the cursor (`mouseCursorName`, on every mouse move);
- the menus (`contextMenuItems()` resolves variables and can run inline Lua);
- the Manage window;
- the Studio: a canvas redrawn up to 30 times a second, 0.5 s ticks that walk every layer, and previews that
  change the running skin;
- the 21 places where the engine hops to the main queue or main run loop (§4.1);
- `--render`, `--snapshot-ui` and the self-tests, which drive skins synchronously and pump `RunLoop.main`.

### 2.2 What stalls whom

| Source of the stall | Where it runs today | Who stalls |
|---|---|---|
| A Lua `Update()` / `!CommandMeasure` / inline Lua call: up to 2 s and 200 M instructions per call | main | every skin and the whole UI |
| WebParser: download and regex run off main, but `FinishAction` (often a Lua parser) runs on main | main | everyone |
| Images: `Images.entry` decodes on first use and after every change on disk (a slideshow skin decodes a new photo every few seconds) | main | everyone |
| Font registration and rescans at load or refresh; `fontsDidChange` re-lays out every skin | main | everyone |
| Loading or refreshing a skin, including the Lua main chunk and the first update | main | everyone |
| `!WriteKeyValue`: synchronous file read and atomic write | main | everyone |
| The Studio: `rebuildSidebar`, `rebuildInspector`, the canvas redraw, previews followed by a write and a refresh | main | every skin |
| The Manage window, the status menu (reads every skin's issues), `NSMenu` tracking | main | skins keep running (timers are in common modes), but the work itself is on main |

The spike reproduces the two shapes of the problem (§7.2):
- a busy main thread freezes every skin for the whole stall;
- a slow skin freezes every other skin for the length of its update.

---

## 3. Goals, non-goals, ground rules

**Goals**
1. No skin is stalled by the UI (menus, Manage window, Studio, installer).
2. No skin is stalled by another skin.
3. Rainmeter's ordering rules still hold (§9). Wherever behaviour changes, the change goes into
   `docs/compat/engine.md`.
4. No CPU or energy regression: skins that cannot be seen do not draw, and a frame costs what it costs today.
5. Incremental: every phase ships, and a setting (`SkinThreading = main | engine | perSkin`) switches back.

**Non-goals**
- Parallelism inside one skin. Measures and meters keep their file order on one thread.
- Swift 6 strict concurrency or actors. The package stays in Swift 5 mode; we use threads, locks and GCD.
- Crash isolation between skins. That would need one process per skin, which is out of scope (§5.7).

**Ground rules**
- **Ownership.** A `Skin` and everything reachable from it is touched only by the thread that currently owns the
  skin: its executor, or a caller holding exclusive access (§5.2). That covers sections, measures, meters, Lua
  states, per-skin caches and timers.
- **Waiting.** The main thread may wait for a skin, but always with a timeout, and it must have a fallback. A skin
  never waits for the main thread and never waits for another skin. Shared services never wait for a skin.
  Everything else is asynchronous.
- **Immutable things cross threads.** Snapshots, `CGImage`s, `CGPath`s, `CTFont`s, strings and value types are fine.
  Mutable objects stay with their owner.

---

## 4. Inventory of main-thread assumptions

What follows is the audit of every place that relies on running on the main thread, grouped by component.
- "Verdict" says what has to happen: *confine* (keep it on the skin's executor), *lock*, *snapshot* (publish an
  immutable value), *hop* (post to the main thread), or *ok*.
- Nothing in the code states the assumption: there is no `@MainActor` or `dispatchPrecondition`, and
  `Thread.isMainThread` appears only in `SystemMonitor`. The compiler reports none of these races (Swift 5 mode).

### 4.1 `Skin` and the engine (DesksetCore)

| Assumption | Where | Verdict |
|---|---|---|
| The skin's state (`measures`, `meters`, `variables`, `settings`, `width`/`height`, `issues`, `burstWork`, `actionDepth`, `mouseContext`, the environment cache…) is unsynchronized mutable state | `Skin` | confine |
| "Read" getters write: `Measure.stringValue` fills `stringCache`, `Skin.styleValues` fills an index, `currentEnvironment` fills a cache; `ownValues` and `StringMeter.fontFolder` are lazy | `Measure`, `Skin`, `SkinSection` | confine. Even read-only UI queries must run on the owner. |
| `SkinSection.skin` is `unowned`. Async callbacks capture sections weakly and then use `self.skin` | `SkinSection` | the executor keeps the `Skin` alive while the work runs; close and dealloc happen on the executor |
| `!Delay`: `DispatchQueue.main.asyncAfter`, guarded by `generation` / `closed` | `Skin.run` | hop to the skin's executor |
| Bitmap transitions: `DispatchQueue.main.asyncAfter`, with no `closed` check and not cancelled by `close()` | `BitmapMeter` | executor timer; cancel on close |
| ActionTimer: `Timer` on `RunLoop.main` (common modes); `invalidate` must happen on the installing thread | `ActionTimerPlugin` | executor timer, cancellable from any thread |
| Plugin completions hop to main: Ping, RunCommand (×5), Quote, FolderInfo, FileView (×4), RecycleManager (×2), ResMon, WebParser (×3). 21 hops in all, counting `!Delay`, Bitmap and ActionTimer | `Plugins/*`, `WebParserMeasure` | pass the executor to the background work and hop back to it |
| `close()` stops only measures that adopt `PluginLifecycle`. WebParser fetches, ResMon lookups and Bitmap transitions are not cancelled. While a closed skin is still alive (during a fade-out, for example), WebParser can still apply results, log and start downloads | `Skin.close` | adopt `PluginLifecycle` (phase 0) |
| Host calls during the update: `textSize` and `imageSize` (layout), `environment(for:)`, `skinNeedsDisplay`, `skin(_:handle:)` / `forward` / `execute`, `log`, `fadeWindow` | `SkinHost` | see §4.2 |
| A bang sent to another config runs synchronously, inside the sender's action. The app cuts A→B→A chains with a static `forwardDepth` ≤ 16 | `Skin.perform` → `SkinController.skin(_:forward:toConfig:)` | message with a hop count (§8.2) |
| `skinNeedsDisplay` only sets `needsDisplay`. Drawing happens after the run-loop turn, so the renderer never sees a half-updated skin | `SkinController` | the skin draws on its own executor, after the update (§7) |

### 4.2 `SkinController`: window, timer, `SkinHost`

| Assumption | Verdict |
|---|---|
| Owns the `SkinPanel` and `SkinView`. `replacePanel` swaps panels when ClickThrough changes. Fades use `NSAnimationContext`. Hover polling uses a main `Timer` | main only; stays in the window half (§5.4) |
| The update `Timer` on `RunLoop.main` with 10 % tolerance; `pauseUpdates` / `resumeUpdates` / `systemDidWake` | executor timer with the same leeway; pause and wake become messages |
| `skinNeedsDisplay`: resizes the window keeping its top-left corner, gates drawing on occlusion (`displayPending`), calls `updateToolTips()` (reads meters) | split: the skin draws its own layer; the size and tooltip rectangles travel in the snapshot; occlusion is a flag the main thread publishes |
| `environment(for:)` reads `window.frame`, `NSScreen` (through `WindowGeometry.currentScreens`), `AppState` and the config editor path | snapshot: an `EnvironmentStore` published by the main thread, plus the skin's own window model (§8.1) |
| `textSize` / `imageSize` / `imageExifOrientation` / `imagePixelAlpha` → static caches | lock or per-skin cache (§4.3, §4.4) |
| `skin(_:handle:)` → `handleHostBang`: window bangs, lifecycle, menus, Manage, Studio, clipboard, wallpaper, sounds, quit | window bangs go to the window model plus a main hop; the rest hops to main (§8.1) |
| `skin(_:execute:)` → `NSWorkspace.open` | hop to main (fire-and-forget) |
| `state` reads `AppState`; `saveFrame` writes it | main only; the skin gets values through the window model |
| `wantsFocus`, read on every click (`needsPanelToBecomeKey`) | snapshot. It is fixed at load. |
| `static var forwardDepth` | hop count carried in the message |

### 4.3 `SkinRenderer` and `Renderers/*`

The draw path is CoreGraphics and CoreText throughout, and it already works in recording contexts (today's
`draw(_:)`). What ties it to the main thread is shared caches and a few AppKit conveniences:

| Assumption | Where | Verdict |
|---|---|---|
| `TextLayout.cache` / `previous`: a static two-generation cache. `TextLayout` objects also mutate themselves (`visibleCache`, `gradientCache`). `TextLayout.make` also calls `Fonts.registerFolder` | `StringRenderer` | per-skin render cache (`SkinRenderContext`) used by both `textSize` and drawing. Only the skin's owner touches it. |
| `RotatorImages.entries` (static LRU) | `RotatorRenderer` | per-skin (a Rotator's processed images belong to its skin) |
| `histogramParts` (static scratch arrays), `histogramCrops` | `HistogramRenderer` | per-skin |
| `RGBA.cgColor` goes through `NSColor(srgbRed:…)` | `Support.swift` | `CGColor(srgbRed:green:blue:alpha:)`: no AppKit, cheaper |
| `PreparedImage`, masks and nine-slice all go through `Images` | `ImageRenderer` | `Images` becomes thread-safe (§4.4) |
| Only drawn when AppKit asks, on main | `SkinView.draw` | the skin's executor draws its own layer (§7) |

### 4.4 `Images` and `Fonts`

| Cache | Today | Verdict |
|---|---|---|
| `Images`: decoded files (`entries`, 512 MB budget, LRU with 5 s keep-alive), derived images (`derived`, 256 MB), `failures`, `alphaMasks`, `nextGeneration`; the doc comment says "Everything runs on the main thread" | static dictionaries, no lock | stays global (decoded photos are big and shared). Lock around lookups and inserts; decode *outside* the lock, with one in-flight marker per path so two skins do not decode the same file twice. `purge` (Refresh All) takes the lock. |
| `Fonts`: `cache`, `faceCache`, `memberCache`, `familyIndex`, `registered`, `registeredFolders`, `missingFolders`, `generation`, `copyCounter` | static, no lock; uses `NSFont(name:size:)` and `NSFont.systemFont` | one lock for resolution. Registration and rescans go on a serial "fonts" queue that skins may wait on (it never waits on a skin). A generation bump sends `fontsChanged` to every skin. Replace `NSFont` with the CoreText equivalents, or keep it under the lock until checked with Main Thread Checker. |

### 4.5 `SystemMonitor`

`SystemMonitor.shared` is handed to every skin as `skin.system`, and nothing in it is protected:
- CPU sampling state, every cache, `diskCache` / `diskPending` / `localVolumes`, `cachedMounts`, and a `lazy var
  dynamicStore`;
- every getter checks, then updates its cache;
- network-volume results are written on main;
- `logonTime()` uses `getutxent`, which is not reentrant;
- `desktopPicturePath()` deliberately returns nil off the main thread. On a skin thread the Registry `Wallpaper`
  value would become empty and add a false compatibility note.

**Verdict:**
- one lock around each cache group (the critical sections are tiny), or a serial sampling queue that publishes
  immutable readings;
- create `dynamicStore` eagerly;
- serialize the utmpx read;
- the desktop picture is published by the main thread (on screen or wallpaper change, at most every 2 s) and read
  from any thread;
- update the contract in `SystemDataSource.desktopPicturePath` and the self-test that expects nil off main.

### 4.6 `NowPlayingCenter` and the other media and UI plugins

| Component | Today | Verdict |
|---|---|---|
| `NowPlayingCenter.shared` | main by convention, no lock. `subscribe` adds a `Timer` to `RunLoop.main` and polls; `snapshot()` writes `lastReadAt` / `lastChoice` and may poll; `perform` uses `NSRunningApplication` / `NSWorkspace`; worker results are written on main through `MediaUIMainHop` | the center keeps its own serial queue (or main); measures read an immutable snapshot under a lock; `subscribe`, `unsubscribe`, `wantsCover` and `perform` are posted to the center; the `Timer` and `NSWorkspace` actions run on main |
| NowPlaying measures | `computeValue` reads the center; `TrackChangeAction` runs `skin.execute` inside `computeValue` | read the snapshot. The action stays on the skin's executor, which is fine. |
| `WiFiCenter.shared`, `FrontmostAppInfo.shared` | unprotected dictionaries mutated by the calling thread; results written on main | lock; results written under the lock |
| `MediaUILocationPermission` | creates a `CLLocationManager` on the calling thread (its delegate needs that thread's run loop) | request on main; publish the status atomically |
| `SysColorMeasure`, `ChameleonMeasure` | `NSApp.effectiveAppearance`, `NSScreen`, `desktopImageURL`, `controller?.window.screen` in the update path; Chameleon writes its palette on main | inputs published by main (appearance, screens, wallpaper); Chameleon's completion hops to the skin's executor |
| `FrostedGlassMeasure` / backdrop | creates and moves an `NSPanel` child window, changes the skin view's layer, from `computeValue` and bangs; static registry, no lock | "window companion" on main, driven by messages carrying the style by value; `deinit` releases on main |
| `InputTextMeasure` / prompt | builds a panel, event monitors, focus handling; its completion mutates the measure and calls `skin.execute`; reads `controller.skin.width` on main | show on main; the completion becomes a message back to the skin's executor; the prompt follows the window, not the skin |
| `MediaKeys` | `NSEvent.otherEvent` → `cgEvent` post; `AXIsProcessTrusted()` in the update path | build a `CGEvent` directly, or hop to main |

### 4.7 `AudioCaptureEngine` and the audio plugins

Already safe off the main thread:
- the engine's state lives on its HAL queue and analysis queue, plus locks;
- `subscribe` and `unsubscribe` post asynchronously;
- the analyzers publish their output under a lock ("any thread");
- `AudioSystem.snapshot()` and `AudioAppCatalog.list()` lock.

Two small fixes:
- `Win7Audio` `ChangeVolume` and `AppVolume` `togglemute` read, then write, with two separate locks. Two skins at
  once can lose a step, where today the main thread serializes them. Make each change one locked operation.
- `AudioSystem.activateIfNeeded()` blocks its first caller for up to 0.2 s. On a skin thread that blocks one skin,
  once. That is acceptable.

### 4.8 WebParser

- Networking (`WebParserNetwork.shared`: locked, serial delegate queue), decoding and regex parsing already run off
  main.
- The options tree is snapshotted on the skin's thread before the fetch.
- **Main-thread work:** applying results to the parent and its children, logging, running `FinishAction` /
  `OnRegExpErrorAction` / `OnConnectErrorAction` / `OnDownloadErrorAction`, and starting child downloads.
- **Verdict:** hop to the skin's executor instead of main, and adopt `PluginLifecycle` so a refresh cancels in-flight
  fetches.
- `WebParserMeasure.allowsFileAccess` is set once by the app (`WebParserAccess`). Its `loggedRefusals` set needs a
  lock.

### 4.9 Lua states

- One `LuaState` per Script measure, created and used on the skin's thread. The C side holds an unretained pointer
  back to it.
- Per-state, so no conflict between skins: the instruction budget, the deadline, the abort flag, the C depth (≤ 32)
  and the hook.
- **C globals:**
  - `total_used` / `total_limit` are `_Atomic`. The 512 MB soft cap can be overshot a little under concurrency,
    which is acceptable.
  - `clock_origin` is set lazily without a lock. Initialize it once, when Lua is registered.
  - `math.random` uses libc `rand()`, one generator for the whole process. That is already shared between skins
    today. A per-state generator is optional.
- **Verdict:** two states on two threads are safe. The risk is **one state used from two threads**: the context
  menu, the inspector or a tooltip resolving `[&Script:…]` on main while the skin's thread runs `Update()`. The
  ownership rule removes it, because those paths run on the owner (§5.2).

### 4.10 `MeasureRegistry` and other process-wide state

| State | Today | Verdict |
|---|---|---|
| `MeasureRegistry` | NSLock; registration at startup | ok |
| `PCRERegexCache.shared`, formula caches, `IniDocument` section index, `TimeLocaleSupport` caches | NSLock; values immutable | ok (contention only) |
| `ProcessSampler.shared` | the start/stop decision is made under the lock but acted on outside it. Skin A leaving while skin B joins can leave B subscribed to a stopped timer | decide and act under the lock, or on the sampler's queue |
| `TrashMonitor.shared` | locked, but one `main.async` runs the waiters of every skin | store `(executor, callback)` per waiter |
| `RegistryMeasure.Facts.shared` | lock held while calling into `system` | compute at startup, or outside the lock |
| `HardwareSensors.source`, `TextDecoding.ansiCodePage`, `FileViewIcons.writer`, `PluginProcess.launcher`, test knobs | unprotected static vars, "set before use" | frozen after launch; set before the first skin starts |
| `IniWriter.writeValue` (`!WriteKeyValue`, Lua `io`, Studio writes) | read-modify-write of a shared `.inc` with no lock | per-file lock, so two skins cannot lose each other's write |
| `Log` | serial queue; `DateFormatter` used only for formatting | ok |
| `AppState` (state.json), `SoundPlayer.current`, `pendingLoads`, `CodeEditorRouter` caches | main by convention | main only; skins send requests |

### 4.11 The UI side: menus, Manage window, Skin Studio

About 620 lines of code in `Sources/Deskset/App` (not counting tests or comments) reach into a skin object directly
(`skin.…`, `.skin`); many more take the skin as a parameter (`LayerNaming.catalog(of:)`, `LayerThumbnails`, …).
About 360 lines of the app's self-tests do the same. The crossings that matter most, in rough order of frequency:

1. Hover: `skin.mouseMoved` (can run actions) plus a cursor hit test, on every mouse move.
2. Tooltips: `toolTipInfo(at:)`, when AppKit asks; the rectangles are rebuilt after every redraw.
3. Clicks that need an answer: the drag decision (`hasAction`, `isOnButton`, `isInDragArea`, the return value of
   `mouseEvent`); the right-click menu (`mouseEvent(.rightUp)`, `hasAction(.rightDoubleClick)`); `wantsFocus`.
4. The Studio canvas: two full `SkinRenderer.draw` passes plus overlays, up to 30 times a second; `contentBounds`;
   hit testing and snapping.
5. The Studio's 0.5 s ticks: live values, the whole `LayerNaming.catalog`, thumbnails (`SkinRenderer.drawMeter`),
   overlays, file stamps.
6. Studio previews: `preview` / `previewVariables` / `endPreview` change the running skin, and the canvas reads
   `frame` back immediately. The desktop shows the preview too.
7. Studio edits: write, then `app.refresh`, then read the *new* skin straight away. This relies on `activate` being
   synchronous.
8. Menus: `contextMenuItems()` (resolved at open time), `metadata`, `issues`. The status menu reads the issues of
   every skin.
9. The Manage window: `metadata` and `issues` on every `desksetSkinsChanged`.
10. Lifecycle: `activate` loads and runs the first update synchronously and returns the controller; `stop` runs
    `OnCloseAction`; quitting closes every skin in reverse load order.
11. `--render`, `--snapshot-ui`, the Manage window's dry-run skins, component thumbnails and `--system-report` load
    throwaway skins on main and pump `RunLoop.main`.

---

## 5. Target architecture

### 5.1 Threads and ownership

```
 main thread                               skin thread (one per skin)            shared services
 ─────────────────────────────             ─────────────────────────────         ───────────────────────
 SkinWindowController                      SkinRuntime                           Images, Fonts (locks)
   NSPanel, SkinView, fades,                 Skin + sections, Lua states         SystemMonitor (locks)
   drag, cursor, tooltips      ─messages─▶   update timer, !Delay, plugins       NowPlaying/WiFi/… centers
   reads SkinSnapshot          ◀─snapshot─   SkinRenderContext (text, rotator)     (snapshots under a lock)
 AppController (lifecycle,                   window model, frame producer        AudioCaptureEngine (ok)
   AppState, SkinDirectory)    ◀─requests─   draws its CALayer, commits          IniWriter (per-file lock)
 menus, Manage, Studio                        from this thread ──────────────▶  window server
```

- A skin's executor runs the whole life of the skin: load, the update timer, bangs, actions, mouse actions, plugin
  completions, `!Delay`, drawing and close.
- The main thread owns every AppKit object and `AppState`.
- Shared services are thread-safe and never call back into a skin synchronously. Their callbacks are posted to the
  skin's executor.

### 5.2 Waiting rules and exclusive access

A thread may wait only for a thread below it in this order: main thread → skin → shared service → leaf lock.
Nothing ever waits upwards or sideways.

- **Skin → main:** only asynchronous posts. Examples: window changes, `NSWorkspace.open`, `AppState` writes, menus,
  lifecycle bangs.
- **Skin → skin:** only asynchronous messages (§8.2).
- **Main → skin, asynchronous:** mouse events, bangs from menus or other skins, focus, pause/resume, previews.
- **Main → skin, exclusive access:**
  `runtime.withExclusiveAccess(timeout:) { skin in … } -> T?`
  - The skin's thread parks between two pieces of work, never in the middle of an update.
  - The main thread then runs the closure itself, with full access to the `Skin`. AppKit calls inside the closure
    are fine, because it runs on main.
  - If the skin does not park within the timeout (it is inside a long Lua call), the call returns nil and the
    caller uses its fallback: the snapshot, the previous value, or "try again on the next tick".
  - Exclusive access is re-entrant for the thread that holds it.
  - It is the tool for rare synchronous needs: context-menu items, some Studio paths (§8.5).

Debug builds assert the rules:
- `Skin.assertOwned()` at the entry points (`update`, `execute`, `perform`, `mouseEvent`, `readOptions`, `preview`,
  …);
- an assertion that a skin thread never calls `DispatchQueue.main.sync`;
- a log line when a skin keeps its thread busy for more than 2 s (a watchdog).

### 5.3 The executor: dedicated threads rather than GCD queues

`SkinExecutor` is a protocol in DesksetCore:
- `async`
- `async(after:)`
- `timer(interval:leeway:)`: cancellable from any thread
- `isCurrent`

It has three implementations:

| Executor | Used for |
|---|---|
| `MainSkinExecutor` | the main queue and main run loop: exactly today's behaviour. Phase 0; also `--render`, `--snapshot-ui`, the self-tests, throwaway skins, and a skin open in the Studio (§8.5). |
| `SkinThreadExecutor` | a dedicated `Thread` with its own run loop. **Recommended for desktop skins.** |
| `SkinQueueExecutor` | a serial `DispatchQueue` (the spike's default executor); kept for comparison and for tests |

Why a dedicated thread per skin:
1. **Stack size.** GCD worker threads have 512 KB stacks; the main thread has 8 MB.
   - The engine was written and tested against 8 MB. Recursion is bounded only by counts: 16 nested actions,
     2 nested updates, 32 Lua C levels, nested variables, 30 `@Include` levels.
   - The code has hit 512 KB before. The formula compiler is iterative because a recursive-descent version needed
     about 800 KB of stack in debug builds for ~130 levels (`FormulaCompiler`), and the PCRE converter keeps its
     recursion shallow for background threads.
   - We measured the worst nesting we could build (§7.4): a release build needs about **70 KB**; a debug build needs
     about **370 KB**.
   - 512 KB is plenty for the shipped app but leaves a debug self-test run only about 1.4× headroom.
   - A `Thread` can have 8 MB, like main, and then nothing changes.
2. **A run loop.** It behaves like a small main thread:
   - `Timer`, `perform(_:with:afterDelay:)` and run-loop sources keep working for plugin code that assumes one;
   - `CATransaction` gets its end-of-turn flush;
   - a display link (`NSView.displayLink`, macOS 14+) can be attached to align fast skins with the display (§7.3).
3. **Predictability.** One thread per skin (typically 5–30) with a stable identity and an explicit QoS:
   - `.userInitiated` for visible skins;
   - `.utility` for hidden or occluded ones;
   - `.userInteractive` for skins that update faster than every 50 ms.

   Idle threads cost only their stack reservation. Only the pages actually touched become resident.

GCD queues would also work for release builds. The protocol keeps that choice open.

### 5.4 Splitting `SkinController`

| Main thread: `SkinWindowController` | Skin thread: `SkinRuntime` (implements `SkinHost`) |
|---|---|
| `SkinPanel`, `SkinView` (a plain container view now, with no `draw(_:)`), fades, `replacePanel`, hover polling | `Skin`, its load and refresh, the update timer, pause and wake |
| Drag, snap and keep-on-screen; saving the position to `AppState` | The window model (§8.1): what the skin believes its window is |
| Cursor, tooltips, focus, turning mouse events into messages | Hit testing and mouse actions on the real skin |
| Applying window requests; publishing occlusion, backing scale, screens and frame into the runtime | `SkinRenderContext` (text layouts, rotator images, histogram scratch space) and the content `CALayer` it draws and commits |
| Reading the latest `SkinSnapshot` | Publishing a `SkinSnapshot` after every update, action or layout |

`AppController` keeps the lifecycle and publishes a `SkinDirectory`. This is an immutable map of config names →
runtimes, groups and load order, replaced atomically on every load or unload. Skins look up the targets of their
bangs in it without asking the main thread.

**Messages to a skin** (from the main thread or another skin):
- input: `.mouse(kind, x, y, double)`, `.hover(x, y)`, `.exited`, `.focus(Bool)`;
- actions: `.bang(bang, from:, hops:)`, `.execute(action)`;
- window: `.windowFacts(frame, screen, occlusion, scale, sequence)`;
- life: `.pause`, `.resume(updateNow:)`, `.wake`, `.fontsChanged`, `.redraw`, `.close(fadeOut:)`.

**Requests to the main thread** (asynchronous, in order):
- window: `.window(model, sequence)`, `.resize(size)`, `.snapshotChanged`;
- app: `.lifecycle(bang)` (Refresh, ActivateConfig / DeactivateConfig / ToggleConfig, RefreshApp, Quit);
- UI: `.ui(bang)` (SkinMenu, TrayMenu, Manage, About, EditSkin);
- system: `.open(target, arguments)`, `.system(bang)` (SetClip, SetWallpaper, Play…);
- companions: `.companion(…)` (FrostedGlass backdrop, InputText prompt).

### 5.5 The snapshot

After every update, top-level action and layout, the skin publishes one immutable value, swapped under a lock. Its
contents:
- the size;
- the window model;
- the hit map: in hit-test order, each meter that has a mouse action, a tooltip, a custom cursor or is a Button,
  with:
  - its frame, and its container clip;
  - for each mouse event kind, whether the action is enabled, disabled or cleared;
  - `MouseActionCursor` / `MouseActionCursorName`;
  - its tooltip text and title;
  - a hit shape: a rectangle, the shape's `CGPath`, or an image path plus transform for a Button's pixel test through
    the thread-safe `Images`;
- `DragMargins`;
- the `[Rainmeter]` actions;
- `wantsFocus`, `toolTipHidden`;
- the context-menu items as of the last update;
- `issues`, `metadata`, `updateCount`;
- a generation number.

The snapshot describes the frame that is on screen. A click is tested against what the user sees, which today is
only nearly true: the skin can have changed since its last draw.

The skin posts one "snapshot changed" note to the main thread, and only when something the main thread uses has
changed (size, hit map, tooltips, window model, issues). A 60 Hz skin whose layout is stable posts nothing.

### 5.6 What stays synchronous

- Within one skin, everything: updates, actions, `!Update`, `!Redraw`, `[Meter:X]` layouts, Lua `SKIN:Bang` flushes,
  and bangs a skin sends to itself.
- Headless modes (`--render`, `--snapshot-ui`, the self-tests, the Manage window's dry runs, component thumbnails)
  use `MainSkinExecutor`, so they behave exactly as today.

### 5.7 Alternatives considered

| Alternative | Why not (or not yet) |
|---|---|
| Keep updates on main and move only drawing off it | Lua, WebParser actions, layout and bangs are the slow parts, so the stalls remain |
| One background engine thread for all skins | Isolates skins from the UI but not from each other. It is our **phase 2 checkpoint** (§10), because it flushes out main-versus-engine races before skin-versus-skin races. |
| One process per skin (XPC) | Adds crash isolation, but windows, caches and fonts would cross process boundaries and every bang would be IPC. Worth revisiting only if crash isolation becomes a goal. |
| Parallel measures inside a skin | Breaks the file-order rules (§9). |
| Swift actors / Swift 6 concurrency | The engine is class-based and in Swift 5 mode. The migration would dwarf this work. Threads with explicit ownership fit what exists. |

---

## 6. What must become thread-safe, and how

| Component | Approach | Phase |
|---|---|---|
| `Skin`, sections, measures, meters, Lua states, per-skin caches | **Confine** to the executor; debug assertions | 0 (seam), 2–3 (move) |
| The 21 engine hops to main, ActionTimer timers, `!Delay`, Bitmap transitions | **Executor**: `skin.executor.async` / `timer` | 0 |
| `close()` coverage (WebParser, ResMon, Bitmap transitions) | `PluginLifecycle`; cancel on close | 0 |
| `TextLayout`, `RotatorImages`, histogram buffers | **Per-skin** `SkinRenderContext` | 1 |
| `Images` (decoded files, derived images, alpha masks) | **Lock**, decode outside it, one in-flight entry per path | 1 |
| `Fonts` (resolution caches, registration, generation) | **Lock** plus a serial fonts queue; `fontsChanged` broadcast | 1 |
| `RGBA.cgColor`, `NSFont` lookups | **Replace** with CoreGraphics / CoreText, or keep under the lock after a Main Thread Checker run | 1 |
| `SystemMonitor` | **Lock** each cache; eager `dynamicStore`; serialized utmpx; **snapshot** of the desktop picture | 1 |
| `NowPlayingCenter`, `WiFiCenter`, `FrontmostAppInfo`, location permission, SysColor / Chameleon inputs | **Snapshot** under a lock; commands **hop** to the center or to main | 1 |
| `ProcessSampler`, `TrashMonitor`, `RegistryMeasure.Facts`, `WebParserAccess` | **Fix** the start/stop race; per-waiter executor; compute outside the lock; lock the set | 1 |
| `IniWriter` read-modify-write | **Per-file lock** | 1 |
| Lua `clock_origin` (and, optionally, a per-state `math.random`) | **Initialize once** at registration | 1 |
| Audio (`Win7Audio` ChangeVolume, `AppVolume` togglemute) | Make each **one locked operation** | 1 |
| `environment(for:)` | **Snapshot**: `EnvironmentStore` (screens, settings path, config editor), plus the window model | 2 |
| `skinNeedsDisplay` | The skin **draws its own layer**; size and tooltips go in the snapshot | 2 |
| Window bangs, `execute`, menus, lifecycle, sounds, clipboard, wallpaper, Manage, Studio | **Hop** to main (async) through a `SkinRequest` | 2 |
| Cross-skin bangs and group bangs | **Messages** through the `SkinDirectory`, with a hop count | 2 |
| Mouse, cursor, tooltips, focus | Decisions from the **snapshot**, events as **messages** | 2 |
| FrostedGlass backdrop, InputText prompt | **Window companions** on main, driven by messages | 2 |
| Context-menu items, Manage details | **Exclusive access** with a timeout; snapshot fallback | 2 |
| Studio | Phase 2: its skin **moves to the main executor** while it is open. Phase 4: **exclusive access** at the Studio's entry points | 2 / 4 |

---

## 7. How finished frames reach the screen

### 7.1 Options

| Option | How | Frames while main is busy | Cost |
|---|---|---|---|
| **A. Draw on main** (today) | Main timer, `needsDisplay`, `draw(_:)` records; the window server rasterizes | stop | lowest in-process cost |
| **B. Hop to main** | The skin updates and draws into a `CGImage` on its thread; `DispatchQueue.main.async { layer.contents = image }` | produced but **not shown** | a new bitmap per frame, plus the main thread's time |
| **C. Commit a `CGImage` off main** | As B, but the skin's thread sets `contents` in an explicit `CATransaction` and flushes | continue | a new bitmap and a copy per frame (~0.6 ms) |
| **D. Commit an IOSurface off main** | The skin draws into one of a few reused IOSurfaces (skipping any `isInUse`), then commits it | continue | no allocation; commit ~45 µs |
| **E. Redraw the skin's own layer off main** | The skin thread calls `setNeedsDisplay()` + `displayIfNeeded()` on its `CALayer` (its `draw(in:)` calls `SkinRenderer.draw`), then commits. The layer *records*, like today's `draw(_:)`, and the window server rasterizes | continue | Deskset's CPU as today; commit ~20 µs |
| F. `CAMetalLayer` | Draw on the GPU, present from the thread | continue | GPU code for every meter type; not needed |

### 7.2 Spike results

The spike (§13) runs two synthetic skins at `Update=16`, each drawing bars, a CoreText label and its frame number
as a row of black and white cells. A sampler thread reads each window back from the window server about 180 times a
second and decodes the frame number that is actually on screen. Measured on an Apple M4 Pro, macOS 26.5.2, 60 Hz
display at 2×. The stall tables show Skin A. Skin B's rows are within 2 frames and 8 ms of Skin A's, apart from one
82 ms freeze outside the stalls in mode C.

**The main thread is busy for 3 × 500 ms** (94 frames expected per skin during the stalls):

| Mode | Frames produced / committed in the stalls | Distinct frames seen on screen in the stalls | Longest on-screen freeze in the stalls (elsewhere) |
|---|---|---|---|
| A. main | 0 / 0 | 4 | 518 ms (36) |
| B. hop | 96 / **0** | 3 | 515 ms (23) |
| C. commit `CGImage` | 95 / 95 | 96 | 24 ms (42) |
| D. IOSurface | 96 / 96 | 95 | 23 ms (26) |
| E. layer, GCD queue | 96 / 96 | 94 | 23 ms (28) |
| E. layer, dedicated thread | 96 / 96 | 96 | 22 ms (28) |

**Skin B's update takes 250 ms four times.** For Skin A, 63 frames are expected during those stalls:

| Mode | Skin A: frames committed / seen in the stalls | Skin A: longest freeze in the stalls | Skin B: longest freeze |
|---|---|---|---|
| A. main | 0 / 5 | 265 ms | 266 ms |
| B. hop | 64 / 64 | 23 ms | 269 ms |
| C. commit `CGImage` | 62 / 64 | 22 ms | 270 ms |
| D. IOSurface | 63 / 64 | 21 ms | 271 ms |
| E. layer, GCD queue | 64 / 64 | 20 ms | 269 ms |
| E. layer, dedicated thread | 64 / 64 | 23 ms | 268 ms |

About the freeze numbers:
- "Freeze" is how long one frame number stayed on screen, as the sampler saw it: from the first sample showing it
  to the first sample showing another.
- Outside stalls it is usually 22–36 ms. That is the 16 ms update period, the 60 Hz refresh and the sampling
  interval added together.
- Skin B's own freeze is its own slow update, in every mode.

**Cost with nothing stalling**, two 60 Hz skins, no screen capture, 5 rounds with the modes interleaved:

| Mode | Draw p50 | Commit p50 / p99 | Deskset CPU (median) | WindowServer CPU, quiet rounds |
|---|---|---|---|---|
| idle (no windows) | – | – | – | 10–12 % |
| A. main | 44 µs (recording only) | – | 4 % | 22–26 % |
| B. hop | 400 µs | 545 / 645 µs | 12 % | 23–28 % |
| C. commit `CGImage` | 400 µs | 585 / 710 µs | 13 % | 25–29 % |
| D. IOSurface | 345 µs | 45 / 105 µs | 5 % | 33–34 % |
| E. layer, GCD queue | 345 µs (`displayIfNeeded`, wall time) | 21 / 43 µs | 5 % | 25–32 % |
| E. layer, dedicated thread | 325 µs | 20 / 40 µs | 5 % | 23–31 % |

How to read these:
- **Deskset's CPU:** E and D cost about what today's model costs. B and C cost about three times as much, because
  they allocate a new bitmap and copy it on every frame.
- **WindowServer's CPU:** it counts everything on the screen.
  - In the first two rounds the screen was busy (38–40 % with no spike windows at all), so only rounds 3–5 are shown.
  - In those rounds E cost the window server 0–6 points more than today's model, and D 7–11 more.
  - A likely cause: every skin commits on its own 16 ms clock (62.5 Hz), where AppKit sends one commit per display
    frame for all windows.
  - Phase 2 measures this with real skins (§10). If the gap holds, aligning each skin's frames with the display is
    the first remedy (§7.3, pacing).

### 7.3 Recommendation and rules

**Use E: the skin redraws its own layer on its thread and commits it from there.**
- The renderer is unchanged: `draw(in:)` calls `SkinRenderer.draw` into a recording context, exactly as today's
  `draw(_:)` does.
- Rasterizing stays in the window server.
- The commit is the cheapest of all the options (about 20 µs).
- D (IOSurface) is the fallback for anything the recording path mishandles.
- B (hop to main) is *not* a fallback for the goal: it keeps skins apart from each other but not from the UI.

Rules for committing off the main thread:
1. Draw only into a **sublayer the skin owns** (`contentLayer`). The layer AppKit creates for the view stays
   AppKit's and is touched only on main.
2. Always use an **explicit transaction**, with implicit animations off:
   - `CATransaction.begin()`, then `setDisableActions(true)`;
   - `setNeedsDisplay()`, then `displayIfNeeded()`;
   - `commit()`, then `flush()`.

   Without `setDisableActions(true)`, a contents change fades over 0.25 s. The flush is needed on threads without a
   run loop, and it is harmless on the dedicated threads.
3. **Size changes.**
   - The skin sets the content layer's bounds in the same transaction as the new frame, anchored top-left under the
     flipped view layer.
   - It also asks the main thread to resize the window. The main thread keeps the top-left corner fixed, as
     `skinNeedsDisplay` does today.
   - For one frame the window can be larger (transparent) or smaller (clipped) than the content, never stretched.
4. **Occlusion and visibility.**
   - The main thread publishes "visible / occluded / hidden" into the runtime.
   - A skin that cannot be seen keeps updating but skips drawing, as today's `displayPending` does.
   - The main thread asks for one frame when the skin becomes visible again.
5. **Backing scale.** The main thread publishes the window's `backingScaleFactor`, and the skin sets
   `contentsScale`.
6. **Pacing.**
   - The update timer is the frame clock. Each update draws at most once, and there is never more than one frame in
     flight, because drawing is synchronous on the skin thread.
   - Later option: for skins faster than every 33 ms, a display link attached to the skin thread's run loop
     (`NSView.displayLink`, macOS 14+) aligns updates with the display. Measure first; `Update=16` is 62.5 Hz on a
     60 Hz screen.
7. The window's alpha, ordering, fades, level and panel replacement stay on main. They are window properties, not
   layer contents.

To verify in phase 2:
- Clicks pass through fully transparent pixels. This works today with layer-backed windows and is expected to still
  work.
- FrostedGlass's corner mask on the view layer.
- Window shadows (off for skins).
- Behaviour in Mission Control and Spaces.
- Live resizing while a skin changes size every frame.

### 7.4 Stack depth

This is the measurement behind §5.3.
- `scripts/spikes/skin-threading/Skins/DeepNesting` is an original fixture:
  - 20 measures whose `IfTrueAction`s chain `!UpdateMeasure` until the engine stops at 16 nested actions;
  - every level also resolves inline Lua (25 nested `pcall`s whose innermost call measures a meter) and a
    `[Meter:W]` layout.
- `stack-probe.patch` makes `--render` run on a thread of a chosen stack size.

Results:

| Build | Smallest stack that works | Crashes at |
|---|---|---|
| release | 80 KB | 64 KB |
| debug | 384 KB | 352 KB |

The default skins and the Lua test skins also render in release with a 64 KB stack.

---

## 8. Crossing threads

### 8.1 Window-level bangs and the window model

The skin keeps a **window model**: position, z-position, alpha and fade, hidden, Draggable, ClickThrough,
KeepOnScreen, SnapEdges, FadeDuration, AutoSelectScreen, plus the facts the main thread publishes (frame, screen,
occlusion, backing scale).

- **The skin's own window bangs** (`!Move`, `!SetWindowPosition`, `!ZPos`, `!SetTransparency`, `!Show` / `!Hide` /
  `!Toggle` and their Fade forms, the flag bangs, `!FadeDuration`):
  - They change the model **synchronously**. Everything the skin reads afterwards (`#CURRENTCONFIGX#` in the next
    action or update, the `SavePosition` rules) sees the result, even before the main thread has moved the window.
    Today the same holds because `!Move` moves the window at once.
  - They then post a `SkinRequest.window(model, sequence)` to the main thread. The main thread applies it in order,
    saves it to `AppState` and echoes back what it really did, clamped by KeepOnScreen and screens.
- **Changes that start on main** (a drag, the skin menu, the Manage window, a screen change) are sent to the skin as
  `windowFacts` with the next sequence number.
- **Conflicts:**
  - Last writer wins, by sequence number.
  - While the user is dragging, the main thread ignores the skin's move requests until mouse-up. Rainmeter's manual
    says nothing about a `!Move` during a drag; this is a judgment call.
- **Bangs aimed at other configs' windows** (`!Move … Config`, the group forms) go to the target skin as messages
  (§8.2). The target applies them to its own model, as above.
- **App-level bangs:**
  - `!Refresh`, `!ActivateConfig`, `!DeactivateConfig`, `!ToggleConfig`, `!RefreshApp`, `!Quit`;
  - `!SkinMenu`, `!TrayMenu`, `!Manage`, `!About`, `!EditSkin`;
  - `!SetClip`, `!SetWallpaper`, `!Play…`.

  These are `SkinRequest`s to the main thread, run later, as `app.later { }` does today. A skin that refreshes or
  unloads itself stops running actions at once, as today, because `closed` is checked after every bang.

### 8.2 Bangs between skins

- **Directory lookup.** A local bang with another config's name, `*`, or a group is resolved by the sender against
  the current `SkinDirectory`. It is then posted straight to each target's executor as `.bang(bang, from:, hops:)`.
  The main thread is not involved, so this works while main is busy.
- **Targets that are loading** are routed through the main thread, which queues the bang behind the load, as
  `isLoadPending` does now.
- **Ordering.** Delivery is FIFO per sender and target, because every executor queue is FIFO. `*` is delivered in
  load order.
- **The sender does not wait.** `[!SetVariable V 1 "B"][!Update "B"]` still works: B sets V, then updates, because
  the two messages arrive in order.
- **What changes:**
  - A's action finishes before B runs.
  - Bangs B sends back arrive after A's action, not in the middle of it.
- **Hop count.** It starts at 0 and each forward adds 1. It replaces the static `forwardDepth`. The limit stays 16,
  and a chain that reaches it is dropped and logged once. This also stops A→B→A ping-pong, which with asynchronous
  delivery would otherwise spin forever.
- **`!UpdateGroup`, `!RedrawGroup`, `!SetVariableGroup`** and the skin-group mouse bangs run synchronously on the
  sending skin when it is in the group, and asynchronously everywhere else.
- **Why this is a judgment call.** The manual does not say whether a bang aimed at another config finishes before
  the sender's next bang. Deskset runs it synchronously today; it becomes asynchronous and ordered. This goes in
  `docs/compat/engine.md` (§9).

### 8.3 Mouse events, cursor, focus

**`SkinView` answers AppKit's synchronous questions from the snapshot:**
- Can this press start a drag? This needs `hasAction(.leftDown)`, whether the press is on a Button's pixels,
  `DragMargins`, Draggable, and whether a double-click or down action catches the press.
- Does this right-click open the skin menu?
- Which cursor goes here?
- Does the panel need to become key? (`wantsFocus`)

**The event itself is a message.** `SkinView` sends `.mouse(kind, x, y)` to the skin: kind, skin-point coordinates,
and whether it is a double click. The skin then runs `mouseEvent` on the live skin, in order.

**Hover** (`.hover(x, y)`, `.exited`) is coalesced: when the skin is busy, only the latest position waits. Hover
events are held while a button is down, as today.

**Button state** (pressed, hovered, captured) lives in the skin. The snapshot only mirrors which Button is pressed,
for the drag decision.

**When the snapshot is behind:**
- The decisions use the frame on screen.
- An action that hides or moves meters is reflected in the next snapshot, one update or one action later. Today's
  "decide before any action runs" order stays the same.
- If the skin is stuck in a long Lua call, the click waits in its queue and runs afterwards. Nothing is lost, and
  the rest of the desktop keeps moving.

**Focus.** `windowDidBecomeKey` and `windowDidResignKey` become `.focus(Bool)` messages. `OnFocusAction` and
`OnUnfocusAction` run on the skin, in the order the changes happened.

### 8.4 Tooltips and context menus

**Tooltips.**
- The snapshot carries each meter's tooltip rectangle (clipped to its container) and its text as of the last
  update, with `%1` already substituted.
- `updateToolTips()` registers the rectangles when the snapshot says they changed.
- `stringForToolTip` answers from the snapshot without touching the skin.

**Skin menu.**
- `contextMenuItems()` is "read at the time the context menu is opened" (manual: `ContextTitle`).
- The main thread asks through **exclusive access with a 50 ms timeout**. When the skin is busy, it uses the items
  from the snapshot, as of the last update.
- Choosing a custom item sends `.execute(action)` to the skin.
- `NSMenu.popUp` (which runs a nested run loop) is only ever called on main.

### 8.5 Skin Studio

The Studio edits the same object the desktop shows, and hundreds of its lines read and write the live skin (§4.11).
It moves in two steps.

**Step 1 (phase 2): a skin open in the Studio runs on the main thread.**
- `attach` moves the runtime to `MainSkinExecutor`.
- The switch happens at a safe point:
  1. the skin thread parks;
  2. its timers are cancelled and re-created on the new executor;
  3. work still queued on the old executor is re-posted to the new one;
  4. `detach` moves the skin back.
- While the skin is on main, every Studio path works unchanged: previews, `m.frame` read-backs, the canvas's
  `SkinRenderer.draw`, write-then-refresh-then-read.
- That one skin can again stall while the Studio is busy, which is acceptable for the skin being edited. Every
  other skin stays isolated.

**Step 2 (phase 4, optional): the edited skin stays on its own thread.**
- The Studio's entry points take exclusive access: `attach`, `tick`, `rebuildSidebar` / `rebuildInspector`,
  `refreshLiveValues`, the canvas `draw(_:)`, gestures, menu builders, previews, `perform`.
- Previews and their read-back run inside one exclusive block:
  ```swift
  runtime.withExclusiveAccess(timeout: 0.05) { skin in
      skin.preview(section: …)
      let frame = skin.meter(named: …)?.frame
      …
  }
  ```
  `skinNeedsDisplay` only schedules a frame on the skin thread, so the desktop shows the preview right after the
  block.
- The canvas draws with exclusive access and a short timeout (8 ms). When the skin is busy, it draws the previous
  canvas image.
- Write, then refresh: `activate` stays synchronous for the Studio. The main thread waits, with a generous timeout,
  for the new runtime to load and run its first update, then reads it with exclusive access.

### 8.6 Manage window, status menu, lifecycle

- **Manage window and status menu:** `metadata` and `issues` come from the snapshot. The "skins changed"
  notification also fires when a snapshot's issues change.
- **`activate`:**
  1. creates the runtime and the window;
  2. the skin thread loads the skin, registers its fonts on the fonts queue, runs the first update and draws;
  3. the main thread waits for "started", with a timeout, and places and shows the window.

  `continueCounter(from:)` reads the old skin's counter before the old runtime is released. The old skin is closed
  on its own thread.
- **Pause and resume, wake, screen changes, `fontsChanged`:** broadcast as messages.
- **Refresh All:** purges the now thread-safe caches, then refreshes the skins in load order.
- **Quit:** `applicationWillTerminate` sends `.close` to every runtime in reverse load order. It waits with a total
  budget (for example 2 s) for the `OnCloseAction`s to finish, then exits.
- **The installer** suspends the affected runtimes and waits for them to acknowledge before it replaces their files.

### 8.7 Command-line modes and self-tests

- `--render`, `--snapshot-ui`, `--system-report`, the Manage window's dry runs and component thumbnails keep using
  `MainSkinExecutor`. `RenderCommand.wait` pumping `RunLoop.main` keeps working.
- The existing self-tests keep their synchronous behaviour.
- New suites cover the threaded runtime (§10).

---

## 9. Keeping Rainmeter's ordering

| Rule (manual) | How it holds |
|---|---|
| Measures update in file order; a measure that references a later one sees its previous value | unchanged: the whole update runs on the skin's thread |
| Meters update and are positioned in file order (`r`/`R`, `[PreviousMeter:X]`) | unchanged |
| `OnRefreshAction` (first update), `OnUpdateAction` and `OnWakeAction` run at the end of the update cycle, then the skin redraws | unchanged; the redraw is the layer commit at the end of the update |
| Actions run in order, synchronously, inside the skin: IfCondition… → OnChangeAction → OnUpdateAction; `!Update` / `!UpdateMeter` / `[Meter:X]` layouts; `burstWork`, `actionDepth`, `updateDepth` limits | unchanged (same thread, same guards) |
| `!Delay`: the rest of the action runs later | `executor.async(after:)` on the same thread; the generation check stays |
| Plugin results arrive between updates (WebParser `FinishAction`, RunCommand, FileView, Ping…) | unchanged; they arrive on the skin's thread instead of main |
| `UpdateDivider`, `Update=-1` (update once), `DefaultUpdateDivider` | unchanged |
| Timer accuracy: `Update=` in ms, minimum 16 | better: no skin waits for another skin or for the UI. The leeway stays 10 % (at most 0.5 s). A timer that fell behind fires once, not in a burst, as with `Timer` today. |
| `#CURRENTCONFIGX#`… after `!Move` | the window model is updated synchronously (§8.1) |
| Mouse actions run on the meter that is hit | the hit test uses the frame on screen (§8.3) |
| `!WriteKeyValue` then `!Refresh Other` | the write finishes (synchronously, under the per-file lock) before the refresh message is sent |
| LoadOrder | z-order and broadcast order unchanged. Different skins' updates were never ordered against each other (each has its own timer). |

The single behaviour change, which goes in `docs/compat/engine.md`:

> ### Bangs sent to other skins run after the sending action
> - Windows (Rainmeter): the manual does not say whether a bang aimed at another config (Config parameter, `*`, or
>   a group bang) finishes before the sender's next bang.
> - Mac (Deskset): each skin runs on its own thread. A bang for another skin is queued for that skin, in order, and
>   the sender goes on at once. The sender's own bangs, including those that name its own config, still run
>   immediately.
> - Why: one skin must not be able to stop another (a slow Lua script, a big file list).
> - Skin impact: sequences such as `[!SetVariable X 1 "Other"][!Update "Other"]` work as before. A chain of skins
>   that trigger each other is cut after 16 hops, as before. A skin cannot rely on another skin having finished its
>   update by the time its own next bang runs.
> - Status: emulated

---

## 10. Migration plan

Every phase ends with both self-test suites passing. Phases 0 and 1 change no behaviour. From phase 2 on, the
`SkinThreading` setting (`main | engine | perSkin`) can switch back.

**Phase 0: the seam and guard rails (3–4 days)**
- `SkinExecutor` with `MainSkinExecutor`.
- `Skin.executor`: all 21 engine hops, ActionTimer, Bitmap transitions and `!Delay` go through it.
- `PluginLifecycle` for WebParser, ResMon and Bitmap transitions.
- Work on the executor keeps the `Skin` alive while it runs; only the executor lets go of a skin.
- Debug ownership assertions.
- A script that runs the app self-tests with Main Thread Checker loaded:
  `DYLD_INSERT_LIBRARIES=/Applications/Xcode.app/Contents/Developer/usr/lib/libMainThreadChecker.dylib`. It works
  outside Xcode.

**Phase 1: thread-safe shared services (6–9 days)**
- Everything in §6 marked phase 1.
- A new "threads" stress suite:
  - loads the TestSkins and DefaultSkins with a thread-safe host;
  - updates and draws each skin on its own thread for 60 s, with the fixture from §7.4 and with slideshow- and
    font-heavy skins;
  - runs under Main Thread Checker.
- ThreadSanitizer as well, once the toolchain allows it. On macOS 26.5 with Xcode 26.2, TSan-instrumented binaries,
  even a trivial C program, crash in the TSan runtime at startup. Retry on each Xcode update and on the CI runners.

**Phase 2: runtime split on one engine thread (10–14 days)**
- `SkinRuntime` / `SkinWindowController`, messages and requests, the snapshot, the window model, `EnvironmentStore`,
  `SkinDirectory`, frame delivery E.
- Mouse, cursor, tooltips and focus from the snapshot. Context menu through exclusive access.
- FrostedGlass and InputText companions. Lifecycle, pause/wake/screens/fonts messages.
- The Studio moves its skin to the main executor (§8.5).
- **All runtimes share one engine thread.** This isolates the UI from every skin while the skins can still only
  race against main.
- Measure real skins on a quiet screen:
  - Deskset and WindowServer CPU for 10 typical skins, against today;
  - frame pacing of an `AudioLevel` visualizer while the Studio is open;
  - energy impact.

**Phase 3: one thread per skin (4–6 days)**
- `SkinThreadExecutor` per runtime, the QoS policy, the watchdog.
- Stress with 30 skins, including the 15 real skin packs used for compatibility testing (local only).
- Check thread count and memory.

**Phase 4 (optional): the Studio on exclusive access (6–10 days)**
- The Studio's entry points (§8.5), so the edited skin also stays isolated.
- Update the Studio self-tests that assume the main executor.

**Phase 5: cleanup (3–5 days)**
- Make `perSkin` the default; keep `main` for debugging.
- Compatibility notes (§9) in `docs/compat/engine.md` and both summaries.
- A one-week soak with real skins. Release notes.

---

## 11. Risks

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| A data race the audit missed (Swift collections crash rather than misbehave) | medium / high | Ownership assertions; the stress suite; Main Thread Checker; the phase-2 checkpoint with one engine thread; TSan as soon as the toolchain works |
| AppKit called from a skin thread (`NSScreen`, `NSWorkspace`, `NSFont`, `NSColor`, `NSEvent`, `NSApp`) | medium / medium | Main Thread Checker on every phase; §4 lists every known call; prefer CoreGraphics / CoreText / snapshots |
| Deadlock | low / high | Waiting rules (§5.2); only bounded waits from main; debug assertion against `main.sync` on skin threads; watchdog log |
| Off-main commits misbehave in some window-server situation (resizing, Spaces, click-through on transparent pixels, FrostedGlass masks) | low–medium / medium | The §7.3 verification list; D (IOSurface) as a fallback; per-skin fallback to B |
| Behaviour change for skins that rely on synchronous bangs to other skins | low / low–medium | Documented judgment call; hop limit; test with the real skin packs |
| Stale snapshot gives a surprising click or cursor for one frame | low / low | The snapshot matches what is on screen; the event still runs on the live skin |
| CPU or energy: many skins committing at 60 Hz, each on its own clock; per-skin caches and threads | medium / medium | No drawing while hidden or occluded; E costs Deskset what A costs in the spike, the window server perhaps a few percent more; measure real skins in phase 2; display-link pacing if the gap holds; the 8 MB stacks are only reserved |
| The Studio's hidden assumptions (synchronous refresh, read-back after preview) | medium / medium | Phase 2 keeps the edited skin on main; phase 4 is optional and bounded |
| Tests that assume main-thread timing (`RunLoop.main` pumping in 48 places, `MediaUIMainHop.runsInline`) | high / low | `MainSkinExecutor` for existing tests; new tests for threads |
| Libraries that are not thread-safe in skin code (`rand()`, `getutxent`, locale functions) | low / low | Found in the audit and listed in §4; fix as listed |
| Priority inversion: the main thread waits for exclusive access on a skin thread with a low QoS | low / low | Exclusive access is rare and bounded; raise the skin thread's QoS while the main thread waits (`pthread_override_qos_class_start_np`) |
| Cross-skin lost updates (`!WriteKeyValue`, audio volume steps) | medium / low | Per-file lock; single locked operations |

---

## 12. Effort

For one developer who knows the codebase:

| Phase | Days | Cumulative |
|---|---|---|
| 0. Seam and guard rails | 3–4 | 3–4 |
| 1. Thread-safe shared services + stress suite | 6–9 | 9–13 |
| 2. Runtime split on one engine thread (UI no longer stalls skins) | 10–14 | 19–27 |
| 3. One thread per skin (skins no longer stall each other) | 4–6 | 23–33 |
| 5. Cleanup, compatibility notes, soak | 3–5 | 26–38 |
| 4. (optional) Studio on exclusive access | 6–10 | 32–48 |

That is about six to eight weeks without phase 4, and seven to ten weeks with it. The largest uncertainties:
- phase 2's window and mouse details;
- how many hidden main-thread assumptions the stress suite turns up in phase 1.

---

## 13. The spike

Everything is in `scripts/spikes/skin-threading/`. It is not part of the Swift package and does not use Deskset's
code.

- **`SkinThreadingSpike.swift`**: a small AppKit program with two synthetic skins in borderless floating panels.
  - Modes: `main`, `hop`, `commit`, `surface`, `layer` (A–E in §7.1).
  - Scenarios: `main-block`, `slow-skin`, `steady`.
  - Executors (every mode except `main`): a serial `DispatchQueue` per skin (`--executor queue`, the default) or a
    dedicated thread with its own run loop and an 8 MB stack (`--executor thread`, what §5.3 recommends).
  - It reports frames produced, committed and **seen on screen** during the stalls. A sampler thread reads each
    window back with `CGWindowListCreateImage`, looked up at run time because the macOS 15 SDK made it unavailable to
    new code. It then decodes the frame number drawn as black and white cells.
  - The spike only checks whether screen capture is allowed; it never asks for it. Without it, the on-screen
    columns read n/a.
- **`run.sh`** builds the program with `swiftc -O` and prints the tables in §7.2:
  - `--cost` prints only the cost table;
  - `--rounds N` repeats the cost table, with the modes interleaved in every round.

  The windows float at the top left of the main screen for a few minutes and let clicks through.
- **`stack-probe.patch`** and **`Skins/DeepNesting`** give the stack measurement in §7.4:
  ```sh
  git apply scripts/spikes/skin-threading/stack-probe.patch && swift build -c release
  DESKSET_RENDER_STACK_KB=64 .build/release/Deskset --render \
      scripts/spikes/skin-threading/Skins/DeepNesting/DeepNesting.ini --updates 1 \
      --skins-dir scripts/spikes/skin-threading/Skins --out "$TMPDIR/deep.png"
  git apply -R scripts/spikes/skin-threading/stack-probe.patch
  ```

**Limitations:**
- The skins are synthetic.
- The frame number is sampled, not timed from vsync.
- One machine and one 60 Hz display.
- WindowServer's CPU is too noisy on a busy desktop to rank the modes.
- It checks that frames arrive and what they cost, not window-server details such as resizing, Spaces or
  click-through (§7.3 lists what phase 2 must verify).

---

## 14. Decisions

Decided on 2026-09-25, all as recommended:

1. **Executor:** a dedicated thread per skin, with its own run loop and an 8 MB stack (§5.3). GCD serial queues
   (`SkinQueueExecutor`) stay for tests and comparisons.
2. **Frames:** the skin redraws its own layer off the main thread and commits it (E, §7.3). IOSurface (D) is the
   fallback.
3. **Bangs to other skins become asynchronous and ordered** (§8.2, §9). Phase 5 records this in
   `docs/compat/engine.md` as a judgment call.
4. **Studio:** phase 2 only for now. A skin open in the Studio runs on the main thread (§8.5); phase 4 is deferred.
5. **The `main` executor stays** after phase 5, as a hidden setting (a `defaults` key, not in the Settings window)
   for debugging and comparisons.

---

## 15. Status

### Phase 0: done (2026-09-26)

Every skin runs on `MainSkinExecutor`, which is the old main queue and main run loop, so skins behave as before. The
only differences are after `close()` (below), while a closed skin is still around during its fade-out, and for a skin
dropped without being closed, whose WebParser transfers are now cancelled (see Lifetime).

**The seam** (`Engine/SkinExecutor.swift`):
- `SkinExecutor`: `async`, `async(after:)`, `timer(interval:leeway:repeats:)`, `isCurrent`. Nothing runs inline, not
  even a 0-second delay or timer. What `async(after:)` and `timer` return (`SkinScheduledWork`) can be cancelled from
  any thread and lets go of its closure at once.
- `MainSkinExecutor` is `DispatchQueue.main.async` / `asyncAfter` (the same FIFO queue as `AppController.later` and the
  media centres' hops, so their relative order is unchanged) and Foundation timers on the main run loop in the common
  modes, with the leeway as tolerance.
- `Skin.executor` (the main executor unless the host picks another before `load()`), `Skin.async` and `Skin.hop()`,
  the way back from background work (`SkinHop.post` from any thread).

**Routed through the skin's executor:**
- The engine: `!Delay`, Bitmap transitions, ActionTimer steps, the Mouse plugin's UpdateRate timer and the Slider's
  HoldDelay timer. The timers have no leeway, as before.
- Plugin results: Ping, RunCommand (exit, decoded output, start failure, Timeout, Close grace period), Quote,
  FolderInfo, FileView (listing and icons), ResMon, WebParser (page, download, bad download URL), and Chameleon in the
  app.
- Shared services hand a skin's callback to that skin's executor, which the caller must name (there is no default, so
  a caller cannot forget it): `TrashMonitor.refresh(on:)` groups its waiters by executor, so the skins on the main
  thread still get one block together, and `PluginProcess.run(_:_:on:completion:)` (RecycleManager's EmptyBin).
- The update clock (`SkinController.startTimer`), with the old 10 % leeway. §4.2 planned this for phase 2; on the main
  executor it is the same timer.

**`close()`:** WebParser, ResMon and `BitmapMeter` adopt `PluginLifecycle`, and `close()` also asks the meters.
- WebParser cancels its page and download transfers. A result that arrives later applies nothing, logs nothing and
  runs no action or child download; a temporary file it saved is deleted, also when the skin is gone by then.
- A ResMon lookup that ends after the unload is dropped.
- A running Bitmap transition stops.
- Pending `!Delay` continuations and RunCommand's Timeout and Close waits are cancelled, rather than left to find the
  skin closed.

**Lifetime:** work queued with `Skin.async` holds the skin until it has run; a result posted with `SkinHop.post`
holds it while it runs. Either way the `unowned` `SkinSection.skin` the work reaches stays valid (§4.1), and only the
executor lets go of a skin, so a skin, its measures and meters are always released there.
- A hop holds the skin weakly, and so does what `post` queues: the executor looks the skin up when the work runs.
  Background work (a 30-second ping, a big folder scan) does not keep an unloaded skin alive, and the thread that
  posts never holds the skin, not even for a moment. Otherwise it could end up with the last reference and release
  the skin off the executor, where an InputText prompt would close its window.
- A result for a skin that is gone is dropped. `post(_:orElse:)` cleans up instead where something must not be left
  behind: a WebParser download saved to a temporary file.
- Closures that run in the background hold measures weakly. WebParser's transfers used to hold their measure; now the
  measures of a skin dropped without being closed go with it and cancel their transfers.

Delayed work and timers do not hold the skin either:
- a day-long `!Delay`, or the ActionTimer animation of a skin that is dropped without being closed (the Manage window's
  dry runs, component thumbnails), must not keep that skin alive;
- such work captures weakly and is cancelled at close; a released skin, measure or meter cancels its own.

**Ownership checks** (debug builds only; `Skin.assertOwned`):
- Where: `load`, `update`, `layout`, `redraw`, `fontsDidChange`, `close`, `focusChanged`, `systemDidWake`, `execute`,
  `perform`, `setVariable`, `contextMenuItems`, the mouse entry points, `SkinSection.readOptionsIfNeeded` and the
  Studio's previews.
- They do not fire in either self-test program, `--render` or the app.
- The stack probe (§13) runs `--render` on a thread of its own: build it in release, as shown there, where the checks
  are compiled out.

**Stays on the main thread, outside the skin's executor:**

| What | Why |
|---|---|
| Fades, hover polling, the FrostedGlass backdrop, the InputText prompt window, `OutsidePointerMonitor`'s monitors and follow timer | Windows and `NSEvent` state: the window half of §5.4 |
| `AppController.later`: lifecycle host bangs, bangs for a config that is loading, `AppState` saves, the installer | The app's lifecycle and state live on main and must stay in order with `later(loading:)` |
| UI events that call the skin synchronously: mouse, hover, focus, context menu, sleep / wake / screens, outside-pointer delivery, the InputText completion | They start on main and use the answer, or must run in the same turn as a panel swap or the Slider's event order. An `async` would add a turn. They become messages in phase 2 (§8.3) |
| The NowPlaying, WiFi and focused-window centres (`MediaUIMainHop`), `SystemMonitor`'s caches | Shared services that never call a skin; skins read them at their next update. Phase 1 gives them locks (§4.5, §4.6) |
| The Studio's timers and deferred edits | The Studio's skin stays on the main executor (§8.5, decision 4) |
| Audio capture, `ProcessSampler`, `WebParserNetwork`, `PluginIO` | Already off the main thread, and they never call a skin |

**Main Thread Checker:** `scripts/check-main-thread.sh` runs both self-test programs with it loaded. First run, all
suites of both programs: nothing reported. The Core program links no AppKit, so today only the app run can report
anything; the checker earns its keep in phases 1 and 2, when host and renderer code starts running on skin threads.

**Tests:** the Core suites "Executor: …" run each kind of work on a test executor that runs nothing by itself: the work
must arrive there, nothing of it has happened until the test runs it, and `close()` cancels what it should. They also
hold a posting thread up inside `post` to show that the executor, not that thread, releases the skin. The app suites
"App: skin threading: …" do the same for the update clock and Chameleon.

**Left for later phases:** the assertion against `DispatchQueue.main.sync` on a skin thread and the busy-skin watchdog
(§5.2), `SkinThreadExecutor` and `SkinQueueExecutor`, moving a skin between executors when the Studio opens it (§8.5).

### Phase 1: in progress

Skins still run on `MainSkinExecutor`, and nothing they do changes, apart from one case under Fonts below. Done so
far:

**Render caches per skin** (`Renderers/SkinRenderContext.swift`, §4.3). A `SkinRenderContext` hangs on
`Skin.renderContext`; like the rest of the skin, only its owner touches it (debug builds check). It holds:
- the skin's text layouts (`TextLayoutCache`). `SkinHost.textSize` now names the skin, so a host that serves several
  skins (`RenderHost` in some self-tests) measures with that skin's layouts, and the String meter is still drawn with
  the layout it was measured with;
- its Rotator images with the image options applied (`RotatorImageCache`, the same 64 MB LRU, now per skin);
- the Histogram's scratch space and cropped images.

What it keeps goes with the skin. Refresh All no longer purges the Rotator images: they go with the skins it replaces.

The text cache still keeps two generations, but they no longer turn over when 1024 layouts from all skins filled them.
They turn over at the skin's next update once the current one holds 64 layouts, and at 1024 in one update. A skin
that keeps showing the same texts builds none of them again; one whose texts keep changing keeps a few dozen layouts.

**Colors:** `RGBA.cgColor` is `CGColor(srgbRed:green:blue:alpha:)` instead of going through `NSColor`: the same
components and color space, also out of range.

**Images** (§4.4) stay shared by all skins, behind one lock:
- lookups and inserts take the lock; decoding a file, making a derived image (orientation, crop and color, flip and
  rotation, strip frames, masked composites) and sampling an alpha mask happen outside it;
- one thread makes each of them. Another thread that needs the same file, image or mask meanwhile waits for it rather
  than decoding it a second time; the maker waits for nothing while it works;
- a result made from a version of the file that was replaced or purged meanwhile goes to its caller but is not kept;
- `purge` (Refresh All) takes the lock.

**Fonts** (§4.4):
- One lock for resolution: the caches, the family index and `generation`. A miss is resolved with the lock held, so
  that nothing resolved from the fonts as they were before a registration is kept after it.
- `NSFont(name:size:)` and the system font stay AppKit calls, under that lock. Core Text's lookups give other fonts:
  an unknown name falls back to Helvetica, PostScript names match in any case, some families get another default
  member, and a system font built from traits snaps weights and widths differently. Main Thread Checker reports
  nothing for them.
- Registration and rescans run on a serial fonts queue, which skins may wait on and which never waits on a skin. A
  folder already read is answered without the queue. A folder counts as read only once its fonts are registered, so
  a thread that finds it read also finds its fonts.
- Every change posts `Fonts.didChangeNotification` on the main thread, a turn later (never in the middle of the layout
  that registered the fonts). The app then lays out its running skins again, each on its executor
  (`AppController.fontsChanged`), unless a caller already did that for this change: a skin's load, an installation,
  Refresh All.
- One thing is new: a font registered by a layout (a skin's `@Resources/Fonts` that appeared after the skin loaded, or
  a skin loaded for a thumbnail or a dry run) now also makes the running skins measure their text again, as a load or
  an installation already did.

**Tests:** "App: skin threading: …"
- `RenderContextSelfTests`: a context per skin, measuring and drawing share it and drawing one skin leaves another's
  alone, layouts are kept and bounded, Rotator images and Histogram crops stay in the skin that drew them, a context
  goes with its skin and a refresh, colors match AppKit's. The Core ownership suite also covers `renderContext`.
- `SharedServiceThreadingSelfTests` use `Images` and `Fonts` from several dedicated threads (8 MB stacks, as in §5.3),
  released together. Several threads wanting one file decode it once, and one derived image is made once (the maker
  is held until the others wait for it). A purge during a decode keeps nothing of it. Files replaced and purged under
  four drawing threads never hand out an image of the wrong version. Fonts and text sizes come out the same on every
  thread as on the main thread. A font folder is registered once, and every thread that asked finds its fonts.
  Rescans under running layouts keep the fonts consistent. A registration is announced on the main thread a turn
  later, and a running skin measures its text again. They also run under Main Thread Checker
  (`scripts/check-main-thread.sh "skin threading"`): nothing reported.
