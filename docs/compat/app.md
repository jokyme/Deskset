# The app: skin windows, mouse, menus, installer UI, permissions (Mac vs Windows)

Area `app`: everything the menu bar app does around the engine — one borderless panel per skin, window settings
(Rainmeter keeps them in Rainmeter.ini, Deskset in `~/Library/Application Support/Deskset/state.json`), mouse handling,
menus, window / config / app bangs the engine hands to the host, the installer UI, fonts, permissions and the
`--render` command.

Code: `Sources/Deskset/AppController.swift` (lifecycle, menus, sleep/wake), `SkinController.swift` (window, mouse,
fades), `App/WindowGeometry.swift` (levels, keep on screen, snapping, visibility rules), `App/SkinBangs.swift`
(host bangs), `App/SkinInstallFlow.swift` + `App/ManageWindowController.swift` (installer UI), `Fonts.swift`,
`Plugins/FileViewIconWriter.swift`, `RenderCommand.swift`, `scripts/build-app.sh` (Info.plist).
Tests: `Deskset --self-test` (suites "App: …"; the ones added with this file: `Deskset --self-test "Info.plist"`,
`"installing ZIP"`, `"font"`, `"FileView icons"`, `"audio capture is suspended"`, `"silence watchdog"`,
`"FadeWindow"`, `"permission and player"`, `"taken back"`, `"command-line flags"`, `"appProvidedMeasures"`,
`"desktop picture"`).

Sources: the manual pages [Skin sections of Rainmeter.ini](https://docs.rainmeter.net/manual/settings/skin-sections/),
[[Rainmeter] section](https://docs.rainmeter.net/manual/skins/rainmeter-section/),
[Default settings](https://docs.rainmeter.net/manual/skins/rainmeter-section/defaults/),
[Mouse actions](https://docs.rainmeter.net/manual/mouse-actions/), [Bangs](https://docs.rainmeter.net/manual/bangs/),
[Manage](https://docs.rainmeter.net/manual/user-interface/manage/),
[Installing skins](https://docs.rainmeter.net/manual/installing-skins/),
[@Resources](https://docs.rainmeter.net/manual/skins/resources-folder/),
[Lua Skin functions](https://docs.rainmeter.net/manual/lua-scripting/) and
[FileView](https://docs.rainmeter.net/manual/plugins/fileview/). Plugin, installer, audio and media details are in
`plugins.md`, `installer.md`, `audio.md` and `media-ui.md`; this file covers the app side of them.

---

## Skin windows

### AlwaysOnTop (Position)
- Windows (Rainmeter): `2` Stay Topmost, `1` Topmost, `0` Normal, `-1` Bottom, `-2` On Desktop (default `0`). The
  manual says skins other than Bottom stay visible when showing the desktop.
- Mac (Deskset): window levels — On Desktop: one above the Finder's desktop-icon level (still clickable and
  draggable); Bottom: one below normal windows; Normal: the normal level; Topmost: the floating level; Stay Topmost:
  one below the menu bar (it covers the Dock). Every skin is on all Spaces and out of ⌘` cycling. All positions except
  Bottom are `stationary` (they stay put during Show Desktop, Mission Control and Stage Manager); Bottom is `transient`
  (Show Desktop / Mission Control hide it). Topmost and Stay Topmost also show over full-screen apps. Clicking a Normal
  or Topmost skin brings it in front of the windows of its level; skins sharing a Position are stacked by Load Order
  (higher in front), then name.
- Why: macOS has window levels instead of Windows' Z-order bands; "stay visible when showing the desktop" maps to
  `stationary`.
- Skin impact: none intended. Stay Topmost skins cover the Dock.
- Status: emulated

### New skins start On Desktop
- Windows (Rainmeter): a config without a Rainmeter.ini section starts with AlwaysOnTop=0 (Normal).
- Mac (Deskset): a config loaded for the first time starts On Desktop (-2) unless the skin sets `DefaultAlwaysOnTop`.
- Why: product decision — Mac users expect widgets to live on the desktop, not over their documents.
- Skin impact: a newly loaded skin sits behind all windows; change it in the skin menu → Position.
- Status: emulated (judgment call)

### Default… options in [Rainmeter]
- Windows (Rainmeter): `DefaultWindowX`, `DefaultWindowY`, `DefaultAnchorX`, `DefaultAnchorY`, `DefaultSavePosition`,
  `DefaultAlwaysOnTop`, `DefaultDraggable`, `DefaultSnapEdges`, `DefaultStartHidden`, `DefaultAlphaValue`,
  `DefaultOnHover`, `DefaultFadeDuration`, `DefaultClickThrough`, `DefaultKeepOnScreen`, `DefaultAutoSelectScreen` are
  used "if the [ConfigName] section does not exist in Rainmeter.ini" and "once used, they will be set as the persistent
  values".
- Mac (Deskset): the same, with state.json in place of Rainmeter.ini: they seed the config's settings the first time it
  is loaded (no entry in state.json yet) and are ignored afterwards. Positions accept the WindowX/WindowY forms (`%`,
  `R`/`B`, formulas, `@N`); unreadable values keep Deskset's defaults.
- Why: —
- Skin impact: none.
- Status: identical

### Draggable, DragMargins and the CTRL override
- Windows (Rainmeter): Draggable (default 1); "LeftMouseDownAction … disables dragging"; DragMargins limits the area a
  drag may start from; holding CTRL overrides mouse actions and Draggable.
- Mac (Deskset): same rules; a drag starts after 3 points of movement. The override key is **⌘ (Command)**: ⌘-drag moves
  any skin (even with Draggable=0, a LeftMouseDownAction or a Button under the pointer) and runs no click action; ⌘
  while dragging inverts SnapEdges. The position is saved when the drag ends (if SavePosition).
- Why: on the Mac, Control-click is the secondary (right) click, so Control cannot be the override.
- Skin impact: tooltips or read-me files that say "hold CTRL" mean ⌘ on the Mac.
- Status: emulated

### DragGroup (moving several skins together)
- Windows (Rainmeter): skins of a DragGroup can be selected and dragged together.
- Mac (Deskset): not supported; each skin moves on its own.
- Why: not implemented yet.
- Skin impact: grouped skins must be moved one by one.
- Status: not supported

### SnapEdges
- Windows (Rainmeter): skins snap to screen edges and other skins (default 1; CTRL disables it temporarily).
- Mac (Deskset): within 10 points of a screen edge (both the full screen and the area below the menu bar / beside the
  Dock) or of a visible skin's edge that is close along the other axis. ⌘ inverts the setting while dragging.
- Why: see "CTRL override".
- Skin impact: none.
- Status: emulated

### KeepOnScreen
- Windows (Rainmeter): "the skin will be kept within the bounds of the screen" (default 1).
- Mac (Deskset): the window is kept on the screen it overlaps most, below the menu bar strip (the Dock area is allowed:
  it may hide). A skin larger than the screen keeps its top-left corner visible. Applied after drags, `!Move`,
  resizes and display changes. With KeepOnScreen off, a skin that ends up entirely off every screen (a display was
  unplugged, a position saved on another setup) is still brought back to the nearest screen.
- Why: a desktop-level window under the menu bar could not be reached; an off-screen skin could never be dragged back.
- Skin impact: none.
- Status: emulated

### ClickThrough
- Windows (Rainmeter): mouse detection off, clicks pass through; "Hold CTRL to temporarily disable".
- Mac (Deskset): the window ignores the mouse entirely (no clicks, hover, tooltips or scrolling). The CTRL / ⌘ override
  is **not** available: macOS does not deliver any event to a window that ignores the mouse. Turn it off from the skin's
  submenu in the menu bar menu or from the Manage window.
- Why: macOS window model.
- Skin impact: a click-through skin cannot be dragged, even with ⌘.
- Status: partial

### Clicks on transparent pixels
- Windows (Rainmeter): fully transparent pixels are not part of the skin (skins use `SolidColor=0,0,0,1` to make an
  area clickable).
- Mac (Deskset): the same through macOS's own hit testing of transparent borderless windows (the window never forces
  mouse handling on). Which meter's action runs is still decided by meter rectangles (see `engine.md`).
- Why: —
- Skin impact: none.
- Status: emulated

### AlphaValue and the Transparency menu
- Windows (Rainmeter): 0 (invisible) … 255; the context menu offers 0 % … 90 % transparency.
- Mac (Deskset): the window's alpha; the menu offers 0 % … 90 % in 10 % steps, the Manage window a slider. `!SetTransparency`
  (and the Group form) sets and saves it.
- Why: —
- Skin impact: none.
- Status: identical

### OnHover
- Windows (Rainmeter): 0 nothing, 1 hide, 2 fade in, 3 fade out (default 0), over FadeDuration.
- Mac (Deskset): same. The manual describes Hide and Fade out alike; Hide also lets clicks pass through while the skin is
  hidden under the pointer, Fade out keeps its mouse actions. The pointer is polled every 100 ms (only for skins with
  OnHover set) so it also works for click-through skins.
- Why: judgment call on Hide vs Fade out.
- Skin impact: none intended.
- Status: emulated

### FadeDuration and fades
- Windows (Rainmeter): FadeDuration (ms, default 250) for OnHover and `!ShowFade` / `!HideFade` / `!ToggleFade`.
- Mac (Deskset): the same fades, plus a fade-in when a skin is loaded and a fade-out when it is unloaded (menu, Manage
  window, `!ActivateConfig` / `!DeactivateConfig` / `!ToggleConfig`). A refresh or a switch to another variant does not
  fade (it would flicker). Values are clamped to 0 … 10 000 ms (`!FadeDuration` too).
- Why: judgment call for load/unload; clamping keeps a typo from freezing a skin.
- Skin impact: none.
- Status: emulated

### Lua SKIN:FadeWindow(from, to)
- Windows (Rainmeter): fades the skin window from one alpha to another at the speed of FadeDuration.
- Mac (Deskset): the window is set to `from` and animated to `to` (both clamped to 0 … 255) over FadeDuration, in order
  with the script's `SKIN:Bang()` calls. The value is **not** saved: it lasts until the skin is refreshed or its
  AlphaValue is set again (`!SetTransparency`, even to the same value, the Transparency menu, the Manage window).
  OnHover and `!Hide` / `!Show` work on top of it. Hosts without windows (`--render`, the engine tests) apply
  `!SetTransparency to` instead.
- Why: the manual does not say whether the faded value persists; keeping it transient never changes the user's saved
  setting behind their back.
- Skin impact: after a refresh the skin starts from its saved AlphaValue again.
- Status: emulated

### StartHidden
- Windows (Rainmeter): the skin starts hidden; `!Show` shows it.
- Mac (Deskset): same (also from `DefaultStartHidden`). A hidden skin keeps updating and running its actions, like one
  hidden with `!Hide`.
- Why: —
- Skin impact: none.
- Status: identical

### Positions: WindowX / WindowY, SavePosition, !Move, !SetWindowPosition, AutoSelectScreen
- Windows (Rainmeter): pixel positions on the virtual desktop; SavePosition (default 1) saves drags; `!SetWindowPosition`
  takes `%`, `R` / `B`, `@N` and anchors.
- Mac (Deskset): positions are points with the origin at the top-left of the primary display (the one with the menu
  bar), y growing downward — the same convention, in points instead of pixels. `!Move` values are clamped to ±1 000 000.
  With SavePosition off, the position is kept for the session only (a refresh keeps it). A new skin without a saved
  position or DefaultWindowX/Y is cascaded from the top-left of the visible area. AutoSelectScreen decides which
  display the monitor variables without `@N` describe.
- Why: macOS works in points (Retina).
- Skin impact: skins positioned for a specific Windows resolution land elsewhere on a Retina Mac; KeepOnScreen keeps
  them visible.
- Status: emulated

### Display changes
- Windows (Rainmeter): not described in the manual beyond KeepOnScreen and the monitor variables.
- Mac (Deskset): when displays are connected, disconnected or rearranged, skins with a saved position are placed from it
  again (so a skin returns to a display that comes back); every skin is then kept on screen (KeepOnScreen) or, with
  KeepOnScreen off, brought back when it is entirely off every display. Skins are not refreshed; the monitor variables
  are dynamic and change for sections with DynamicVariables=1.
- Why: judgment call.
- Skin impact: a skin that computed its layout from `#SCREENAREAWIDTH#` without DynamicVariables keeps it until it is
  refreshed.
- Status: emulated

### Sleep, displays asleep, other user sessions
- Windows (Rainmeter): OnWakeAction runs "when Windows returns from the sleep or hibernate states".
- Mac (Deskset): while the Mac sleeps, the displays sleep or another user's session is in front, skin timers stop (no
  updates, no drawing) and so does audio capture for AudioLevel / AppVolume (no recording indicator, no analysis). They
  resume with an immediate update. After a real sleep OnWakeAction runs at the end of that update (at once for
  `Update=-1` skins). Skins hidden with `!Hide` keep updating and keep their audio capture (a hidden visualizer may be
  waiting for sound to show itself).
- Why: energy; macOS reports display sleep and session switches separately from system sleep.
- Skin impact: measures of time-based skins jump forward after the pause (Uptime, Time are read fresh).
- Status: emulated

### Focus: OnFocusAction / OnUnfocusAction
- Windows (Rainmeter): the skin "receives focus" when clicked; "loses focus" when something else is clicked.
- Mac (Deskset): skin windows never activate Deskset (the app in front stays in front). A skin window takes keyboard focus
  only when it has OnFocusAction or OnUnfocusAction (or to take the focus away from another skin); the actions run at
  once when macOS reports the change, not at the end of the next update. Typing into a focused skin is swallowed
  silently.
- Why: non-activating panels are what Mac widgets use; see `engine.md` for the timing.
- Skin impact: none intended.
- Status: emulated

### Blur and BlurRegion ([Rainmeter]), blur bangs
- Windows (Rainmeter): "Set to 1 to enable Aero Blur"; `!ShowBlur`, `!AddBlur`… change it.
- Mac (Deskset): not supported (the FrostedGlass plugin is, see `media-ui.md`). The bangs add a compatibility note.
- Why: not implemented yet.
- Skin impact: the skin is drawn without the blurred backdrop.
- Status: not supported

---

## Mouse

### Right click and the skin menu
- Windows (Rainmeter): right-click opens the skin menu unless RightMouseUpAction / RightMouseDownAction /
  RightMouseDoubleClickAction is set; CTRL+right-click always opens it.
- Mac (Deskset): same rules. A Control-click (the Mac's secondary click) and ⌘+right-click always open the skin menu.
- Why: Mac conventions.
- Skin impact: none.
- Status: identical

### Middle, X1 and X2 buttons
- Windows (Rainmeter): Middle / X1 / X2 actions (extra buttons "may not work for everyone").
- Mac (Deskset): mouse buttons 3, 4 and 5 run the Middle, X1 and X2 actions. Trackpads have no such buttons.
- Why: —
- Skin impact: none.
- Status: identical

### Scroll actions
- Windows (Rainmeter): MouseScrollUp/Down/Left/RightAction once per wheel notch.
- Mac (Deskset): wheel notches map one to one. Trackpad scrolling runs one action per 24 points of finger travel (at
  most 10 per event) and none during momentum. Directions are physical — fingers moving up is "up" whatever the Natural
  Scrolling setting.
- Why: Windows skins expect discrete notches; Natural Scrolling would otherwise flip every skin.
- Skin impact: scroll-driven skins (volume, lists) feel like on Windows.
- Status: emulated

### Hover while a button is held
- Windows (Rainmeter): not described.
- Mac (Deskset): MouseOver / MouseLeave are not updated while a mouse button is held; entering or leaving during a press is
  reported when the buttons are released.
- Why: the engine treats a hover update as the end of a press.
- Skin impact: none.
- Status: emulated

### Cursors (MouseActionCursor, MouseActionCursorName)
- Windows (Rainmeter): a hand over meters with mouse actions (MouseActionCursor=1 default); MouseActionCursorName takes
  Windows cursor names or `.cur` / `.ani` files from `@Resources\Cursors`.
- Mac (Deskset): HAND, TEXT, CROSS, NO, SIZE_WE and SIZE_NS map to the macOS cursors; every other name (HELP, BUSY, WAIT,
  PEN, SIZE_ALL, the diagonal sizes, UPARROW) and custom `.cur` / `.ani` files show the arrow. A Button meter's image
  shows the hand.
- Why: macOS has no public equivalents for those cursors; `.cur` / `.ani` are Windows formats.
- Skin impact: some skins show the arrow where Windows shows a custom cursor.
- Status: partial

### Tooltips
- Windows (Rainmeter): ToolTipText / ToolTipTitle, ToolTipIcon, ToolTipType (balloon), ToolTipWidth; ToolTipHidden in
  [Rainmeter].
- Mac (Deskset): standard macOS tooltips, one area per meter (moving to another meter shows its tooltip), the title on
  its own line above the text. ToolTipIcon, ToolTipType and ToolTipWidth are read but not shown. No tooltips for hidden
  meters, the content of hidden containers, ClickThrough skins or ToolTipHidden=1. They show whichever app is in front:
  macOS shows a window's tooltips only while its app is active unless the window allows them in the background, and
  Deskset — a menu bar app whose skin windows never activate it — is almost never active, so skin windows allow them
  (found in review: without that, skin tooltips almost never appeared). They appear after half a second, Windows'
  default; AppKit's own delay is two to three seconds for a background app (a value set for all apps with
  `defaults write -g NSInitialToolTipDelay` still wins).
- Why: macOS tooltips have no icon, balloon style or width setting.
- Skin impact: tooltips look like other Mac tooltips.
- Status: partial

---

## Menus and the Manage window

### Skin context menu
- Windows (Rainmeter): skin name, Variants, Settings (Position, Transparency, Hide on hover, Draggable, Click through,
  Keep on screen, Save position, Snap to edges…), Manage, Edit, Refresh, Unload, custom skin actions.
- Mac (Deskset): the skin's name, its custom actions, Variants, Position, Transparency, On Hover, Draggable, Click Through,
  Keep on Screen, Snap to Edges, Save Position, "Compatibility Notes (n)" when the skin has any, Manage Skin…, Edit
  Skin… (the Skin Studio), "Edit in <app>" when a code editor app is chosen in Settings ▸ Editor, Refresh Skin, Open Skin
  Folder, Unload Skin. FadeDuration and Load Order are set in the Manage window; StartHidden and AutoSelectScreen come
  from the skin's Default… options and bangs only.
- Why: Mac menu conventions.
- Skin impact: none.
- Status: emulated

### Custom skin actions (ContextTitle / ContextAction)
- Windows (Rainmeter): "Up to 25 ContextTitleN options"; "If more than 3 options are given, 'Custom skin actions'
  becomes a submenu"; titles are dynamic.
- Mac (Deskset): same (the engine reads the titles when the menu opens); `!SkinCustomMenu` shows only them.
- Why: —
- Skin impact: none.
- Status: identical

### Main menu (the tray menu)
- Windows (Rainmeter): the notification-area icon's menu; `!TrayMenu` opens it.
- Mac (Deskset): the menu bar icon's menu (Manage Skins…, Skins, loaded skins, Refresh All, Install Skin…, Open Skins
  Folder, Open Log, Launch at Login, About, Quit); `!TrayMenu` pops it up at the pointer. macOS may hide menu bar icons
  (System Settings → Menu Bar): opening Deskset again from Finder, Spotlight or Launchpad shows the Manage window, and
  the first launch shows it too. A second copy of Deskset hands its files over to the running one and quits.
- Why: macOS 26 lets the user hide menu bar extras.
- Skin impact: none.
- Status: emulated

### Compatibility notes
- Windows (Rainmeter): n/a.
- Mac (Deskset): things that work differently on the Mac (Windows-only measures and plugins, unsupported bangs, refused
  permissions, players without a Mac version…) are listed per skin in the skin menu and the Manage window; mistakes that
  Rainmeter treats the same way only go to the log. For a skin that is not loaded, the Manage window checks it without
  a window and without updating it (no audio capture, no permission prompt), so notes only a running skin can find — a
  refused permission — appear once it is loaded.
- Why: users need to know why a skin shows no data.
- Skin impact: none.
- Status: Deskset extension

---

## Config and app bangs

### When !Refresh, !ActivateConfig, !DeactivateConfig and !ToggleConfig happen
- Windows (Rainmeter): the manual does not say when during an action a skin is loaded, unloaded or refreshed.
- Mac (Deskset): they run on the next turn of the app's run loop, after the action that asked for them has finished
  (a skin's OnRefreshAction that refreshes itself, or two skins refreshing each other, can never recurse). Bangs of
  the same action addressed to a config that is about to be loaded wait for it: `[!ActivateConfig X][!Move 10 10 X]`
  moves the newly loaded X. A skin cannot reload or unload itself from its OnCloseAction.
- Why: judgment call for robustness.
- Skin impact: none observed.
- Status: emulated

### !ActivateConfig for a config that already runs that file
- Windows (Rainmeter): `!ActivateConfig Config File` "Activates a skin"; without File, "the next .ini file variant in
  the config folder is activated" (https://docs.rainmeter.net/manual/bangs/). The manual does not say what happens
  when the config is already active with that file. Forum threads about a log warning that the config is "already
  active" suggest that Rainmeter leaves the skin as it is.
- Mac (Deskset): nothing happens apart from a warning in the log (`!ActivateConfig: "Config\File.ini" is already
  active`). File names are compared ignoring case. A file the config folder does not have falls back to the last used
  file, as it does for a config that is not running, so it too leaves the running skin alone; so does
  `!ActivateConfig Config` for a config with a single .ini file, which is its own next variant. Another variant still
  replaces the running one. `!Refresh`, `!ToggleConfig`, the Manage window and the menus are not affected.
- Why: judgment call. Reloading would let a skin that activates its own config reload itself endlessly, reading its
  web page again each time: Monstercat Visualizer's update notice activates itself on every load while a newer
  version exists.
- Skin impact: none expected; a skin that wants to reload itself uses `!Refresh`.
- Status: emulated (judgment call)

### !RefreshApp and Refresh All
- Windows (Rainmeter): refreshes Rainmeter and all skins.
- Mac (Deskset): re-reads the Skins folder, decodes images again, reads every known `@Resources/Fonts` folder again
  (added, replaced and removed fonts) and refreshes every skin. The app itself is not restarted.
- Why: —
- Skin impact: none.
- Status: emulated

### Layouts: !LoadLayout
- Windows (Rainmeter): layouts save and restore sets of loaded skins with their settings.
- Mac (Deskset): layouts from packages are installed into `~/Library/Application Support/Deskset/Layouts` but cannot be
  applied yet; `!LoadLayout` adds a compatibility note, and a package that asks to load a layout says so after
  installing.
- Why: not implemented yet.
- Skin impact: suites that set themselves up through a layout must be loaded skin by skin from the Manage window.
- Status: not supported

### Other host bangs
- Windows (Rainmeter): `!SetClip`, `!SetWallpaper`, `!Play` / `!PlayLoop` / `!PlayStop`, `!Manage`, `!About`,
  `!EditSkin`, `!Quit`, `!ResetStats`, `!SetAnchor`.
- Mac (Deskset): `!SetClip` sets the pasteboard; `!SetWallpaper` sets the desktop picture of every display (Tile shows
  the picture unscaled like Center: macOS cannot tile); `!Play` plays one sound at a time; `!Manage` opens the Manage
  window on the named config; `!About Log` opens the log; `!EditSkin` opens the file in the text editor; `!Quit` quits
  after the current action. `!ResetStats` and `!SetAnchor` add a compatibility note.
- Why: —
- Skin impact: none for the supported ones.
- Status: emulated

---

## Installing skins (the app side; package handling is in `installer.md`)

### What can be opened
- Windows (Rainmeter): double-clicking a `.rmskin` runs the Skin Installer; other formats are installed by hand.
- Mac (Deskset): `.rmskin` files, ZIP archives and folders can be double-clicked (`.rmskin` only: Deskset is its default
  app), opened with "Open With → Deskset", dropped on the app icon or on the Manage window, or chosen with Install Skin…
  (the panel accepts all three). Deskset registers for ZIP archives and folders with `LSHandlerRank=Alternate`, so it
  never becomes the default app for them. Several items are installed one after another. A folder that is the Skins
  folder or lies inside it is refused before anything is copied ("already in the Skins folder" — skins placed there by
  hand appear after Refresh All); so is a folder that contains it, such as the home folder ("contains Deskset's Skins
  folder": choose the skin's own folder). Other files get "Deskset installs skin packages (.rmskin), ZIP archives with
  skins and folders with skins."
- Why: most download sites hand out ZIPs or folders; installing the Skins folder into itself would copy every skin.
- Skin impact: skins that need "extract into Documents\Rainmeter\Skins" on Windows install with one click.
- Status: emulated

### The confirmation
- Windows (Rainmeter): the Skin Installer shows the header image, name, author, version, the skins and layouts, and
  whether plugins are included.
- Mac (Deskset): an alert with the header image (RMSKIN.bmp), "Install “Name”?", author and version, then: for a plain
  archive or folder a note that it was not made with the Skin Packager and the skins were found automatically (a
  folder is copied, the original stays), for a legacy Rainstaller package a note saying so; the root configs with their
  configs and whether they replace (backed up) or add to installed ones; layouts (saved, not applied); fonts the
  installation adds to `@Resources/Fonts` ("not installed system-wide"); what loads afterwards; the Windows plugins
  (never installed) and other warnings. Errors: "This file or folder doesn't contain any Rainmeter skins.", "It
  contains several skin packages (…). Open them one at a time (extract the archive first when it is one).", damaged
  archives.
- Why: —
- Skin impact: none.
- Status: emulated

### After installing
- Windows (Rainmeter): the old version of a skin is backed up and replaced; the package's skin or layout is loaded.
- Mac (Deskset): running skins of a replaced root config are stopped first and loaded again afterwards; the fonts of the
  installed root configs are read again before any of their skins loads (skins already on screen are measured again);
  installed fonts are written to the log; the package's skin is loaded with a fade and selected in the Manage window.
  Notes that only appear during installation are shown in a second alert.
- Why: —
- Skin impact: none.
- Status: emulated

---

## Fonts

### @Resources/Fonts and LocalFont
- Windows (Rainmeter): TrueType and OpenType fonts in `@Resources\Fonts` "are automatically loaded"; LocalFont loads a
  font file for the skin.
- Mac (Deskset): `.ttf`, `.otf`, `.ttc` and `.otc` files are registered for the Deskset process only (never installed in
  macOS). What is registered is a private copy (a clone, no extra space on APFS) in `~/Library/Caches/Deskset/Fonts`
  (the temporary folder for command-line runs), because Core Text can only unregister a file that still exists: when
  the original is replaced (an update, a reinstall) or deleted, the old font is unregistered and the new one
  registered at the next load, refresh, installation or Refresh All. The copies are not kept in the temporary folder
  because macOS empties it nightly of files older than three days (a clone keeps the original's dates); a copy deleted
  by a cleaning utility is made again from the unchanged original at the next load or refresh. A
  font folder that does not exist yet is looked for again after 5 seconds (and at once by those events), not
  remembered as missing for good. When fonts change, skins already on screen are measured and laid out again.
- Why: macOS registers fonts per process; skins measured before their font existed would keep fallback metrics.
- Skin impact: fonts of a skin are available to every other skin in Deskset too (as on Windows, where they are loaded
  for Rainmeter as a whole).
- Status: emulated

---

## FileView icons (Type=Icon)

### Icon files
- Windows (Rainmeter): the child measure saves the item's icon to `IconPath` (default `icon<Index>.ico` in the skin
  folder) at IconSize (16 / 32 / 48 / 256 pixels) for an Image meter to show.
- Mac (Deskset): the Finder icon of the file or folder (NSWorkspace), rendered at that pixel size and written
  atomically on a background queue. For `.ico` paths up to 256 pixels it is a real Windows icon file (ImageIO's ICO
  encoder); otherwise PNG data is written whatever the extension — the Image meter recognises both from the content.
  Missing folders on the IconPath are created.
- Why: macOS icons come from NSWorkspace; `.ico` is kept so the path the skin expects exists.
- Skin impact: icons look like Finder icons.
- Status: emulated

---

## Permissions

### Permission prompts and Info.plist
- Windows (Rainmeter): skins read audio, players, Wi-Fi names and files without asking.
- Mac (Deskset): macOS asks the first time a loaded skin needs a protected feature, with the texts in Info.plist:

  | Feature | macOS permission | Info.plist key | When refused |
  |---|---|---|---|
  | AudioLevel `Port=Output`, AppVolume peaks (macOS 14.2+) | Screen & System Audio Recording → System Audio Recording Only | `NSAudioCaptureUsageDescription` | levels read 0 |
  | AudioLevel `Port=Output` (macOS 13 – 14.1) | Screen Recording (then restart Deskset) | — | levels read 0 |
  | AudioLevel `Port=Input` | Microphone | `NSMicrophoneUsageDescription` | levels read 0 (tried again every 10 s) |
  | NowPlaying / iTunes / WebNowPlaying, RecycleManager Empty, FileView Properties | Automation (Music, Spotify, Finder) | `NSAppleEventsUsageDescription` | player shown as closed; Trash / Get Info do nothing |
  | WiFiStatus SSID and LIST | Location Services | `NSLocationUsageDescription`, `NSLocationWhenInUseUsageDescription` | names empty |
  | Skins and scripts reading Desktop, Documents, Downloads, removable or network volumes | Files and Folders | `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` | the file reads fail |
  | WebParser / Ping to devices on the local network | Local Network | `NSLocalNetworkUsageDescription` | the request fails |
  | MediaKey media keys | Accessibility (never asked; granted by the user) | — | play / track keys reach Music and Spotify only |
  | GetActiveTitle window titles | Accessibility, else Screen Recording (never asked) | — | no title |
  | RecycleManager `RecycleType=Size` | Full Disk Access (never asked) | — | 0 and a compatibility note (Count works without it) |

  `NSAllowsArbitraryLoads` stays on (WebParser skins read plain http:// feeds). A bundled app that uses a protected
  feature without its usage description would be killed by macOS; the audio backends refuse instead.
- Why: macOS privacy (TCC).
- Skin impact: a prompt the first time; after a refusal the feature shows empty values (never a crash or a hang).
- Status: emulated

### Refused permissions become compatibility notes
- Windows (Rainmeter): n/a.
- Mac (Deskset): besides the log line, the skin gets a compatibility note when: the microphone is refused (Port=Input);
  on macOS 13 – 14.1 Screen Recording is missing; a system-audio stream carried nothing but digital silence over two
  looks 10 seconds apart while another app was playing sound (the usual sign of a refused System Audio Recording
  permission, which macOS reports as silence); Location Services are off for a WiFiStatus SSID / LIST measure; Deskset
  may not control Music or Spotify; a MediaKey track key is sent without Accessibility (it reaches only Music and
  Spotify); RecycleManager `RecycleType=Size` cannot list the Trash (no Full Disk Access). Player names without a Mac
  version (Winamp, foobar2000, AIMP, WMP, MusicBee…) and WebNowPlaying (Deskset does not connect to its browser
  extension) also get a note.
  A permission note is taken back (`Skin.removeIssue`) as soon as it no longer applies: the microphone note once the
  source runs (a refused input source is started again every 10 seconds, because macOS sends no notification when the
  user changes the setting); the silence note once sound arrives (the watchdog keeps looking while the note is shown);
  the Location Services note at the WiFiStatus measure's next update after they are allowed; the Accessibility note
  at the MediaKey measure's next update or key; the Automation note when the player answers again (re-checked every
  30 seconds); the Full Disk Access note once the Trash size can be read (read again at least every 30 seconds).
  Screen Recording on macOS 13 – 14.1 needs the restart of Deskset it asks for; Full Disk Access, when System Settings
  offers to quit and reopen Deskset, applies after that restart. When several measures of a skin report
  the same note, the others add it again at their next update.
- Why: users need to know why a skin stays empty and where to fix it, and a note that no longer applies would send
  them to System Settings for nothing.
- Skin impact: none.
- Status: Deskset extension

---

## `Deskset --render` (development and compatibility testing)

### What differs from the app
- Windows (Rainmeter): n/a.
- Mac (Deskset): `Deskset --render Skin.ini --out x.png [--updates N] [--interval ms] [--scale S] [--background R,G,B[,A]]
  [--skins-dir DIR]` loads the skin without a window, runs N updates (default 2, 1 000 ms apart), draws it at scale S
  (default 2, at most 16 384 pixels a side) on a transparent or given background and prints compatibility notes and
  skin log lines. There is no window: window, config and app bangs are accepted and ignored (Lua FadeWindow falls back
  to that ignored `!SetTransparency`), mouse actions never run, the Skins folder is the nearest ancestor named `Skins`
  (or `--skins-dir`). Nothing asks for a permission: nothing is captured, since only skins in skin windows capture
  (`DESKSET_AUDIO_DEMO=1` feeds a generated signal), players look closed (`DESKSET_NOWPLAYING_DEMO=1` fakes a playing
  track), Location and Automation are never used. Fonts in `@Resources/Fonts`, FileView icons and the
  Registry `Wallpaper` value work as in the app.
- Why: repeatable screenshots without prompts or a visible screen.
- Skin impact: none (developer tool).
- Status: Deskset extension

### Command-line flags
- Windows (Rainmeter): n/a.
- Mac (Deskset): the binary's development modes are `--render`, `--self-test [filter]`, `--snapshot-ui`,
  `--system-report` and `--make-icon`; `--help` / `-h` prints them (exit status 0). An argument starting with `--` that
  is none of these flags or their options (`--out`, `--updates`, `--interval`, `--scale`, `--background`,
  `--skins-dir`, `--dark`, `--select`, `--size`, `--zoom`), or such an option without a mode, prints the usage to
  stderr and exits with status 2. Other arguments are left alone, so Finder / LaunchServices launches (`-psn_…`) and
  AppKit defaults (`-NSDocumentRevisionsDebugMode YES`) still start the app. (`--plist` belongs to
  `scripts/build-app.sh`, not to the binary.)
- Why: a mistyped development command (`--selftest`) used to fall through to the menu bar app, which then loaded and
  changed the user's real skins and settings.
- Skin impact: none (developer tool).
- Status: Deskset extension
