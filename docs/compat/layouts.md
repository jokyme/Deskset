# Layouts

Scope: an independent implementation of the Rainmeter Layouts workflow. This does not add a gallery, layout history,
skin backup manager or skin-file export. Windows desktop comparison remains pending. Current verification is on macOS;
implementation and self-tests are not evidence of a Windows parity run.

### Save, load, delete and edit
- Windows (Rainmeter): [Manage → Layouts](https://docs.rainmeter.net/manual/user-interface/manage/#LayoutsTab)
  saves and restores configuration settings. Its save options are empty layout, exclude unloaded skins and include
  current wallpaper. Skin files are not part of a layout. Normal loads save the previous configuration as `@Backup`
  after close actions; loading `@Backup` itself keeps that backup unchanged and ignores its wallpaper.
- Mac (Deskset): Manage has the same actions and three save options. A named layout lives at
  `~/Library/Application Support/Deskset/Layouts/<name>/Rainmeter.ini`. Nonempty exports use UTF-16 LE with a BOM;
  an empty layout is a zero-byte file. Selecting empty clears and disables the other two options. Overwriting an
  existing layout requires confirmation; Save cannot manually replace `@Backup`. Saving without a new wallpaper
  preserves any existing picture and other files in that layout folder. Delete confirms before moving the whole
  folder to the Trash; a failed Trash operation is reported without permanently deleting it. The list includes
  existing layout directories even if their INI is missing. Edit opens the INI with the configured editor.
  Loading replaces per-config state, including inactive configs. Normal loads save `@Backup` after close actions;
  loading it leaves the backup unchanged. An empty desktop remains empty after restart. The status menu lists layouts.
  Exclude unloaded skins removes only sections whose stored `Active` value is exactly `0`.
- Why: Rainmeter's public layout format is the exchange format; state.json remains an internal implementation detail.
  Unknown config keys are retained without implying that their runtime behavior is implemented.
- Skin impact: missing targets are rejected before unloading. A later read, backup or wallpaper failure is reported
  and restores the previous skin session; close-action side effects are not undone. The store rejects directory
  traversal and symbolic links, including links in a folder being preserved during overwrite. A saved layout does
  not change plugin compatibility.
- Status: emulated

### Application settings
- Windows (Rainmeter): a normal load preserves nonempty previous values of `SkinPath`, `ConfigEditor`, `Logging`,
  `DisableVersionCheck`, `DisableAutoUpdate`, `Language`, `NormalStayDesktop`, `SelectedColor` and
  `HardwareAcceleration`. Nonempty previous `TrayExecuteM`, `TrayExecuteR`, `TrayExecuteDM` and `TrayExecuteDR` values
  fill empty or missing target values. Other target `[Rainmeter]` options can apply; the whole section is not ignored.
  Loading `@Backup` restores its global settings without these normal-load preservation rules.
- Mac (Deskset): raw `[Rainmeter]` and optional `[TrayMeasure]` sections survive layout saves and application restarts.
  Normal loads merge the stored global values using the preservation rules above; `@Backup` restores its saved raw
  values. Local editor, update, installation and other application preferences remain separate and unchanged.
  Preserving Windows global and tray options does not implement their unsupported runtime behavior.
- Why: the platforms have different application settings. Retaining layout metadata allows a round trip without
  treating unsupported Windows settings as working Mac preferences.
- Skin impact: a layout that depends on changing Windows global settings needs separate configuration on macOS.
- Status: partial

### Config variants, order and positions
- Windows (Rainmeter): [skin sections](https://docs.rainmeter.net/manual/settings/skin-sections/) use `Active=0`
  for an unloaded config and a one-based variant index otherwise. Variant order depends on the filesystem's file
  enumeration, so there is no universal numeric or Unicode ordering. Equal `LoadOrder` values use INI
  section order. Window and anchor positions accept formulas, percentages, edge-relative values and monitor suffixes.
- Mac (Deskset): captures active and inactive configs, `WindowX/Y`, `AnchorX/Y`, `SavePosition`, `AlwaysOnTop`,
  `Draggable`, `ClickThrough`, `KeepOnScreen`, `SnapEdges`, `StartHidden`, `AlphaValue`, `OnHover`, `FadeDuration`,
  `LoadOrder`, `AutoSelectScreen`, `Group` and `DragGroup`. Config groups join the skin's groups; storing DragGroup does
  not implement the still-missing group-selection UI. Layout expressions and anchors survive save/reload and apply
  when the skin size is known; anchors continue to affect resizing. A monitor suffix on just one axis applies to
  both. `SavePosition=0` keeps a session move separate from saved coordinates. An imported missing `AlwaysOnTop`
  uses the Rainmeter default `0`; the existing default for newly created Mac config state is unchanged.
  Missing configs and out-of-range variant indices remain recorded, and are skipped rather than loading another
  variant. Variants use a fixed case-insensitive alphabetical comparison, separate from Manage's natural ordering.
  Imported `Active` text, or its absence, is retained until activation or variant changes. Saving also updates the
  index if newly discovered files shift the current variant's position in the list.
  Rainmeter 5.0's native `Zoom` percentage maps to the existing zoom factor, constrained to 10–500%; exports do not
  create a `ZoomFactor` layout key.
- Why: macOS window geometry is measured in points. Deskset's deterministic alphabetical order does not promise
  the same variant index for every Windows filesystem or Unicode filename. `!SetAnchor` and the remaining 5.0 zoom
  UI/global settings remain outside this implementation.
- Skin impact: display sizes, font metrics and supported skin/plugin behavior can still differ across platforms.
  Unsupported original config options survive a layout round trip but do not gain functionality through persistence.
- Status: emulated / partial

### Layout wallpaper
- Windows (Rainmeter): [Manage → Layouts](https://docs.rainmeter.net/manual/user-interface/manage/#LayoutsTab)
  can include the current wallpaper when saving, and applies a saved wallpaper when loading.
- Mac (Deskset): saves the primary display's readable desktop image under `Wallpaper.bmp`, retaining the original
  image bytes and encoding rather than requiring BMP encoding. A normal load applies
  that image to every connected display while retaining each display's current macOS scaling/clipping options.
  A layout without wallpaper leaves desktop pictures unchanged. Dynamic, rotating and video desktop configurations,
  per-display pictures and Spaces assignments are not serialized. Unreadable desktop images cause save failure.
  Automatic `@Backup` saves configuration settings only; it does not capture a
  desktop picture or remove a previously saved backup image. Loading `@Backup` ignores any wallpaper it contains.
  If applying a normal layout's picture fails, the previous desktop configuration is restored.
- Why: macOS exposes desktop pictures per display; the implementation maps Rainmeter's single layout picture to
  that API. Desktop picture formats, dynamic pictures and Spaces cannot be transferred as Windows desktop settings.
- Skin impact: restoring a layout does not restore dynamic-wallpaper playback or a different image on each monitor.
  Original test images and an injected wallpaper boundary keep automated tests from changing the user's desktop.
- Status: partial

### Bangs, command line and package installation
- Windows (Rainmeter): [`!LoadLayout LayoutName`](https://docs.rainmeter.net/manual/bangs/#LoadLayout) loads a named
  layout, including from the command line. Manage and the installer provide the corresponding UI entry points.
- Mac (Deskset): skin `!LoadLayout`, `!Manage Layouts`, the status menu and a package's selected included layout use
  the same coordinator. The executable accepts `Deskset '!LoadLayout' "Layout name"` and `Deskset '!Manage' Layouts`
  (single quotes prevent shell history expansion).
  A request reaches the running user's instance, or starts that instance when none is running. This is a bounded
  command interface, not a general shell or arbitrary-bang command evaluator. Layout loads are serialized around
  installation and skin shutdown. An installed layout still has the package author's `[Rainmeter]` settings removed;
  the apply checkbox determines whether installation also replaces the desktop. When applying a package layout,
  all old skins close before package files are replaced. Their close actions can finish against the old files;
  `@Backup` captures the resulting settings with the old variant list. A close timeout cancels installation before
  file replacement. Without application, the layout is installed only.
- Why: macOS application launch and same-user command delivery replace Windows process messaging. No new public
  layout commands or private keys are needed, and applying an installed layout does not require restarting the Mac process.
- Skin impact: package layouts can be applied without manually loading each skin. An unavailable skin or plugin
  remains unavailable; importing its layout is not a promise that the skin will work on macOS.
- Status: emulated

### Close actions during layout replacement
- Windows (Rainmeter): [OnCloseAction](https://docs.rainmeter.net/manual/skins/rainmeter-section/#OnCloseAction)
  runs when a skin unloads; [actions](https://docs.rainmeter.net/manual/skins/option-types/#Action) can include
  bangs and external commands.
- Mac (Deskset): old skins close sequentially in config-name order. Supported local, cross-config, UI, system and
  open actions run during each close; remaining configs stay addressable until their own close starts. New configs
  created by close actions are also closed before replacement. Waiting for the initiating action, closing and
  request draining share one total 10-second budget; if it expires, remaining old instances are stopped and retired.
  Later requests from retired
  instances are discarded. Explicit `!LoadLayout`,
  `!RefreshApp` and `!Quit` requests wait in their original order until the current layout finishes.
- Why: skin work and window operations use separate executors on macOS. The coordinator preserves close-action
  effects while preventing old asynchronous work from changing the replacement desktop.
- Skin impact: close cleanup and cross-config effects can influence `@Backup`. Existing cross-config deactivation
  fade timing, filesystem name ordering and other platform differences remain; a Windows desktop comparison has
  not been completed.
- Status: emulated / partial
