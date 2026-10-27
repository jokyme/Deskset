# The app: skin windows, mouse, menus, installer UI, permissions (Mac vs Windows)

Area `app`: everything the menu bar app does around the engine — one borderless panel per skin, window settings
(Rainmeter keeps them in Rainmeter.ini, Deskset in `~/Library/Application Support/Deskset/state.json`), mouse handling,
menus, window / config / app bangs the engine hands to the host, the installer UI, fonts, permissions and the
`--render` command.

Code: `Sources/Deskset/AppController.swift` (lifecycle, menus, sleep/wake), `SkinController.swift` (window, mouse,
fades), `App/WindowGeometry.swift` (levels, keep on screen, snapping, visibility rules), `App/SkinBangs.swift`
(host bangs), `App/SkinInstallFlow.swift` + `App/ManageWindowController.swift` (installer UI), `Fonts.swift`,
`Plugins/FileViewIconWriter.swift`, `RenderCommand.swift`, `Location/LocationCenter.swift` (Location Services),
`Weather/WeatherWiring.swift` + `Weather/WeatherCommands.swift` (the weather service's wiring, the skin menu's credit,
the weather reports), `scripts/build-app.sh` (Info.plist).
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

### Skin zoom (Rainmeter 5.0)
- Windows (Rainmeter): `Zoom` is an integer percentage from 10 to 500. `!SetZoomFactor Factor|Default [Config|*]`
  and `!SetZoomFactorGroup Factor|Default Group` set a skin or group; `DefaultZoom` and `ForceDefaultZoom` are global settings.
- Mac (Deskset): Manage's Skins page has a Zoom field and stepper; Settings → General has Default zoom and Force.
  Steps are one percentage point, or ten with Control. The skin menu's Zoom offers Default and
  80/90/100/110/120/130/140/150%. With no overrides, only Default is checked. Otherwise a common effective percentage
  is checked, inserting a custom value in order as a non-action item; different effective values leave all items unchecked.
  Missing `Zoom` follows the global default; explicit `Zoom=100` remains an override. Default removes the override.
  Force applies the global value and disables per-skin zoom controls without discarding existing overrides.
  Rendering, window size, mouse actions, hover, tooltips and external pointer coordinates use the effective zoom;
  zoom changes redraw independently of the skin's regular update interval. Group menus show only common values.
- Why: window positions are macOS points; skin zoom and display backing scale are separate factors. The global
  controls use the existing Mac Settings window. Windows desktop comparison remains pending.
- Skin impact: turning Force off restores each skin's own override, or its inherited default. Layouts retain
  `Zoom`, `DefaultZoom`, `ForceDefaultZoom` and `SelectedColor`; see [Layouts](layouts.md).
- Status: emulated / partial (platform geometry and pending Windows desktop comparison)

### Draggable, DragMargins and the CTRL override
- Windows (Rainmeter): Draggable (default 1); "LeftMouseDownAction … disables dragging"; DragMargins limits the area a
  drag may start from; holding CTRL overrides mouse actions and Draggable.
- Mac (Deskset): same rules; a drag starts after 3 points of movement. The override key is **⌘ (Command)**: ⌘-drag moves
  any skin (even with Draggable=0, a LeftMouseDownAction or a Button under the pointer) and runs no click action; ⌘
  while dragging inverts SnapEdges. The position is saved when the drag ends (if SavePosition). A `!Move` or
  `!SetWindowPosition` the skin runs while a press on it may drag the window waits for the release: a press that
  became a drag wins and the move is dropped; otherwise the move is made at the release.
- Why: on the Mac, Control-click is the secondary (right) click, so Control cannot be the override. The manual does
  not say what a `!Move` during a drag does (judgment call).
- Skin impact: tooltips or read-me files that say "hold CTRL" mean ⌘ on the Mac. A skin that moves itself while it is
  being dragged ends where the pointer let go of it.
- Status: emulated

### Global DisableDragging
- Windows (Rainmeter): `DisableDragging` defaults to `0`; enabling it prevents mouse dragging of active skins
  (<https://docs.rainmeter.net/manual/settings/rainmeter-section/#DisableDragging>).
- Mac (Deskset): Settings → General provides Disable dragging. The saved global setting blocks ordinary mouse
  drags for existing and newly loaded skins, without rewriting each skin's Draggable preference. Enabling it ends
  an ordinary or selected-skin drag already in progress; disabling it requires a new press before dragging again.
  Click actions, pointer notifications and programmatic moves remain available. The existing Command override
  and selected-skin keyboard/resize rules are retained.
- Why: the global mouse setting is applied at the input boundary, separately from persistent per-skin preferences.
- Skin impact: a desktop can be locked against ordinary accidental dragging without changing its saved skin flags.
- Status: partial. Public documentation does not specify the global setting's precedence against Ctrl override,
  selected-skin keyboard movement or resizing; those Windows combinations remain unverified.

### DragGroup (moving several skins together)
- Windows (Rainmeter): skins of a DragGroup can be selected and dragged together.
- Mac (Deskset): Control-Option-click selects or deselects a skin; Select skin is also available in its menu.
  Selecting a skin includes skins with a matching DragGroup. Selected skins move together and accept shared menu
  settings. Normal skin mouse actions, hover effects and tooltips are suspended while selected; temporary drag,
  click-through and keep-on-screen overrides do not replace stored settings. Clicking outside clears selection.
  Dragging an edge changes each selected skin by the same percentage-point delta, clamped to 10–500%; a corner
  drag locks to one axis after movement begins. Left/top drags shift all selected windows by the primary skin's
  size change, following the 5.0 RC1 behavior; this does not hold the opposite edge fixed. Edge hit areas account
  for the display backing scale separately from skin zoom.
- Why: Control-Option is the Mac selection chord; ordinary Command-drag keeps its existing override behavior.
- Skin impact: group position, zoom and shared settings can be edited together. A click-through skin is selected
  with Control-Option-click like any other (see ClickThrough) or through the menu. Windows desktop comparison remains
  pending.
- Status: emulated / partial (platform geometry)

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
- Mac (Deskset): the window ignores the mouse entirely (no clicks, hover, tooltips or scrolling). Holding ⌘ or Control
  with the pointer over the skin lets the mouse reach it while the key is held (`ClickThroughOverride`): ⌘-drag moves
  it, Control-click opens its menu, Control-Option-click selects it, mouse actions and hover work. A press made during
  the override keeps it until every button is up; a press already under way elsewhere starts none. The modifier keys,
  buttons and pointer are polled every 0.1 s, only while a skin is click-through. Tooltips stay off; the saved setting
  is unchanged.
- Why: macOS delivers no event to a window that ignores the mouse; watching keys in other apps needs Accessibility,
  while reading the current modifier state does not.
- Skin impact: none intended.
- Status: emulated

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
  hidden with `!Hide`. The Manage window marks it as hidden and can show it (see "A loaded skin that is hidden").
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
  display the monitor variables without `@N` describe. Imported layout position expressions and anchors persist
  across save/reload, movement and resizing; see [Layouts](layouts.md). `!SetAnchor` changes the anchor dynamically
  as described below.
- Why: macOS works in points (Retina).
- Skin impact: skins positioned for a specific Windows resolution land elsewhere on a Retina Mac; KeepOnScreen keeps
  them visible.
- Status: emulated

### Dynamic anchors (`!SetAnchor`)
- Windows (Rainmeter): `!SetAnchor AnchorX AnchorY [Config]` changes the skin's anchor settings. Anchors accept
  pixels, percentages of the skin's dimensions, and `R` / `B` edge-relative values; the modifiers can be combined
  (<https://docs.rainmeter.net/manual/bangs/#SetAnchor>,
  <https://docs.rainmeter.net/manual/settings/skin-sections/#AnchorX>).
- Mac (Deskset): the bang uses the existing current/config/`*` target routing, including `Skin:` target-first forms.
  Changing the anchor adjusts the top-left corner around the same window-position point, subject to KeepOnScreen.
  Pixel anchors follow the applied skin zoom; percentage anchors follow its current size. Existing `WindowX/Y`
  expressions and monitor/edge suffixes remain intact. With SavePosition off, a live session move stays separate
  from the saved position. Legacy coordinates with no raw expressions are normalized using their saved point.
  Moves held during a press retain their command order; an actual drag takes precedence. Invalid anchor arguments
  leave the window and its saved settings unchanged. First positioning reuses the normal session/layout/default/
  cascade priority, rather than treating the unplaced panel as a saved position.
- Why: one placement calculation is shared by initial positioning and dynamic anchors; it uses macOS points.
- Skin impact: skins can change anchors without refreshing and keep their position expressions through reloads.
- Status: emulated / partial. Exact Windows first-frame scheduling, commands issued before initial meter geometry,
  and concurrent-start cascade sampling remain unverified. Cascade fallback uses an activation-time snapshot when
  an early positioning command needs it; ordinary startup keeps its existing placement timing.

### Position menus and active-skin selection
- Windows (Rainmeter): Settings → Position includes Display monitor, the five window levels, From right, From bottom,
  X as percentage and Y as percentage. Manage also provides Display monitor and an Active skins pull-down
  (<https://docs.rainmeter.net/manual/user-interface/context-menus/>,
  <https://docs.rainmeter.net/manual/user-interface/manage/>). Selecting a monitor writes `@N` and disables
  AutoSelectScreen; Use default removes the directive. `@0` denotes the virtual desktop.
- Mac (Deskset): the same documented entry points are available. Display monitor lists the default, virtual desktop
  and connected monitors, plus Auto-select based on window position. Coordinate-mode switches re-encode the position
  without moving the window, preserving anchors and zoom. A monitor choice transfers the live screen-relative offset
  to that display and applies the existing KeepOnScreen rules. Display directives retain formulas. With SavePosition
  off, representation edits preserve the saved location instead of committing an unsaved drag. Group menus apply
  common choices to selected skins; Manage's Display monitor control edits only its selected active variant. Its X/Y fields remain actual
  desktop coordinates in points. Its Active skins list contains loaded config/INI paths, is disabled when empty,
  and only selects and scrolls to the file; it does not load, show or raise the skin. Stale choices are ignored.
- Why: reuses the existing coordinate parser, window constraints and layout/state persistence; no new INI keys.
- Skin impact: display and relative-coordinate settings are accessible without editing a layout by hand.
- Status: partial. macOS verification covers the controls and coordinate conversions. Exact Windows monitor-list
  labels/order, coordinate conversion and rounding during menu actions, SavePosition-off persistence details,
  cross-screen KeepOnScreen timing and Active skins sorting remain unverified.

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
- Windows (Rainmeter): "Set to 1 to enable Aero Blur on the Windows 7 operating system"; `!ShowBlur`, `!HideBlur`,
  `!ToggleBlur`, `!AddBlur` and `!RemoveBlur` change it. The manual notes it "will not work on Window 8.1 or
  Windows 10", and Rainmeter 5.0 requires Windows 10 or later, so on current Windows they have no visible effect.
- Mac (Deskset): the same. `Blur` and `BlurRegion` are read and nothing is drawn; the five bangs are accepted with no
  effect (the rest of the action runs), without a compatibility note or log line. The FrostedGlass plugin
  (`media-ui.md`) and `MacGlass` (`engine.md`) draw frosted backgrounds on the Mac.
- Why: matches Rainmeter 5.0 on Windows 10 and 11; drawing the Windows 7 blur would make skins that still set
  `Blur=1` differ from current Windows.
- Skin impact: none compared with current Windows. Not compared on a Windows desktop.
- Status: identical

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
- Mac (Deskset): Select skin, the skin's name, its custom actions, Variants, Zoom, Settings (Position, Transparency,
  On Hover, Draggable, Click Through, Keep on Screen, Snap to Edges, Save Position, Favorite),
  "Compatibility Notes (n)" when the skin has any, Manage Skin…, Edit
  Skin… (the Skin Studio), "Edit in <app>" when a code editor app is chosen in Settings ▸ Editor, Refresh Skin, Open Skin
  Folder, Unload Skin. FadeDuration and Load Order are set in the Manage window; StartHidden and AutoSelectScreen come
  from the skin's Default… options and bangs only. Zoom, Position, Transparency, On Hover and the window-setting checkboxes
  apply to the selected group when this skin belongs to it; mixed values are unchecked. Refresh Skin and Unload Skin
  also apply to the selected group, clearing its selection as the instances stop.
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
- Mac (Deskset): the menu bar icon's menu (Manage Skins…, Skins, Favorites, Layouts, loaded skins, Refresh All, Install Skin…, Open Skins
  Folder, Open Log, Debug, Launch at Login, About, Quit); `!TrayMenu` pops it up at the pointer. macOS may hide menu bar icons
  (System Settings → Menu Bar): opening Deskset again from Finder, Spotlight or Launchpad shows the Manage window, and
  the first launch shows it too. A second copy of Deskset hands its files over to the running one and quits.
- Why: macOS 26 lets the user hide menu bar extras.
- Skin impact: none.
- Status: emulated

### Favorites and skin discovery
- Windows (Rainmeter): Favorite is available in Manage for an active skin and in the skin's Settings menu.
  The main Favorites submenu provides shortcuts to those skins
  (<https://docs.rainmeter.net/manual/user-interface/context-menus/>,
  <https://docs.rainmeter.net/manual/user-interface/manage/>). Rainmeter 5.0 checks for skin-folder changes when
  opening a context menu, switching to Manage or activating a config (<https://www.rainmeter.net/changes-5.0/>).
- Mac (Deskset): the same Favorite entry points update saved shortcuts to individual config/INI pairs. Manage
  disables Favorite unless the selected file is running. Favorites appears between Skins and Layouts, is disabled
  when empty, lists available shortcuts in library order and marks the loaded file. Shortcuts survive unloading
  and restarting; local layouts leave them unchanged. Missing files are omitted from the menu without clearing
  their saved shortcuts. Opening menus or Manage, returning to Manage, selecting its Skins tab and activating configs
  rescan the library; changes update lists without reloading or unloading running skins.
- Why: local application preferences store shortcuts independently of window and layout settings.
- Skin impact: manually copied skins and new variants become selectable without Refresh All.
- Status: partial. The documented entry points and active-skin checkbox state are implemented. Windows comparison
  of Favorite's variant scope, menu hierarchy and sorting, empty state, active-item click and layout persistence
  remains pending. Favorites are local preferences and are not imported or exported with layouts.

### Debug and About
- Windows (Rainmeter 5.0): Debug contains Log, Skins, Display, Network and Plugins. It opens from the tray menu,
  Ctrl-clicking the tray icon, Manage's Open log button, a skin's Debug skin item, and
  `!Debug [Log|Display|Network|Plugins|Skin] [Config]`. About contains version information separately
  (<https://docs-v5.rainmeter.net/manual/user-interface/debug/>,
  <https://docs-v5.rainmeter.net/manual/user-interface/about/>, <https://www.rainmeter.net/changes-5.0/>).
- Mac (Deskset): Debug uses the same five pages in a shared native window. Left-clicking the menu bar icon opens
  Manage; Control-left-click opens Debug, and right-click opens the menu. The window remembers its size.
  Log starts with the latest 50 messages, newest first; Type filters affect new messages, Clear empties the panel,
  and Command-C copies selected message text. The live panel retains the existing 2,000-entry safety bound. The Log file menu starts/stops disk logging, opens the file or deletes
  it while stopping logging. Skins uses an active-config popup and a Name/Number/String table grouped into Measures,
  Variables and Watch. A measure's Number tooltip exposes its unchanged range. Disabled measures are gray and paused
  measures have a yellow background. Values display up to 512 characters plus an ellipsis; copies retain full values.
  Filter searches measure and variable names and values; Jump to navigates the groups. Double-clicking a measure or
  variable adds a string watch. The watch editor evaluates strings or formulas against current runtime values without
  an implicit skin update; Execute sends a string action through the skin's existing command queue. Inline script or
  plugin functions can perform their normal side effects. Watches live for this Debug window session, grouped by skin.
  Refresh on file change watches the selected skin's INI, included files and loaded Lua scripts, coalesces changes,
  ignores unchanged contents and stops repeated refresh loops. Control-R or F5 refreshes the selected skin manually.
  A measure's context menu can open its definition in the configured editor.
  Display shows available macOS displays, logical screen/work areas and display-local physical pixel areas; a global
  physical-pixel virtual desktop is unavailable on macOS. Network lists local interface facts and includes virtual
  interfaces when selected. Display and Network support copying a value or the full list.
  Plugins lists the registered built-in implementations with known aliases consolidated, the Deskset version marked
  `(bundled)` and author `jokyme`. All listed implementations update with the app; external plugins remain unsupported.
  About copies app version, bundle build number when available, architecture and program/settings/skin/log paths.
- Why: native macOS controls and device APIs, existing command execution and bounded log storage.
- Skin impact: use `!Debug` for diagnostics. Existing `!About` command tokens remain accepted but show version details.
  Build date and Windows plugin binaries are unavailable; network indices are BSD indices, not Windows interface IDs.
- Status: partial. macOS tests cover runtime reads, asynchronous cancellation, menus, clipboard and file-change behavior.
  Windows desktop comparison remains pending, including filter matching, watch persistence, legacy `!About` parameters,
  unknown-tab/config fallback, logging/filter persistence and exact file-change storm thresholds. Public 5.0 pages still
  contain older four-tab/20-message text; the five-page screenshots and 50-message release note take precedence.
  Meter-definition navigation remains pending verification of its interaction; measure-definition navigation is available.

### Persistent file logging
- Windows (Rainmeter): `Logging` defaults to `0` and settings are saved automatically. In Debug, Start logging
  enables file output, Stop logging retains the file, and Delete log file deletes it while stopping output
  (<https://docs.rainmeter.net/manual/settings/rainmeter-section/#Logging>,
  <https://docs.rainmeter.net/manual/settings/>, <https://docs-v5.rainmeter.net/manual/user-interface/debug/>).
- Mac (Deskset): the existing Debug Log file menu saves `Logging=1` or `0` immediately. The primary instance applies
  that value before startup messages reach a file. Disabled logging neither creates nor rotates the log; the
  in-memory panel remains available. Stop drains earlier writes and retains the file. Delete stops output and
  closes the handle before removal; a removal failure is reported and leaves logging disabled across restart.
  Ordinary layouts retain local Logging, including its default-off value when no key is present.
- Why: file output follows the same persisted global option as the controls, while retaining the existing log queue.
- Skin impact: restarting Deskset preserves the user's file-logging choice; existing files are retained by Stop.
- Status: emulated. Exact Windows file-error behavior and backup-layout global-setting exceptions remain unverified.

### Cumulative network statistics
- Windows (Rainmeter): `Cumulative=1` on NetIn, NetOut and NetTotal reads saved traffic statistics. Settings provides
  Reset statistics; `!ResetStats` clears the same statistics. After a cumulative measure has been active in the
  current session, statistics are gathered and saved periodically, every two minutes, and saved on exit
  (<https://docs.rainmeter.net/manual/measures/net/>, <https://docs.rainmeter.net/manual/bangs/#ResetStats>,
  <https://docs.rainmeter.net/manual/user-interface/manage/#SettingsTab>, <https://docs.rainmeter.net/history/>).
- Mac (Deskset): cumulative measures share per-interface totals, stored separately from layouts in
  `network-statistics.json` in the app's settings folder. The primary desktop instance loads them before skins and
  saves them on exit. Its two-minute collection/save task starts with the first cumulative read and continues for
  that session after cumulative skins unload. Ordinary rate reads and Reset statistics alone do not start it.
  Settings → General's Reset statistics and `!ResetStats` clear all totals through the same service; a following
  measure-update bang sees the reset immediately. Raw interface counters and ordinary speed measurements remain
  unchanged. Recording a skin does not reset live statistics.
- Why: one shared sampler avoids counting the same traffic repeatedly when multiple measures read an interface.
  A fresh baseline is used after startup, reset, a decreasing counter or an interface reappearing; traffic while
  Deskset is closed is not added. Disconnected interfaces retain their accumulated totals.
- Skin impact: cumulative counters persist between sessions and can be reset without reloading skins. The native
  storage is not a Rainmeter statistics-file interchange format.
- Status: emulated / partial. macOS tests cover collection, persistence, ordering and failure paths. Windows desktop
  comparison remains pending, including initial baselines, offline traffic, interface disappearance and file errors.

### The default skins and the first launch
- Windows (Rainmeter): Rainmeter comes with a default skin suite, illustro, which it loads when it is first installed
  (<https://docs.rainmeter.net/manual/getting-started/>).
- Mac (Deskset): Deskset comes with its own original skins, the Stationery suite (the folders in `DefaultSkins`,
  root config `Stationery`: 17 widgets and 6 collection pieces). They are copied into the Skins folder at the first
  launch and again when a newer Deskset brings new ones (a version number in the app): the old copy moves to
  `Backups/<Root>-examples-v<N>`, and the settings the user changed in its `@Resources/Variables.inc` are written into
  the new one. A value the old version shipped and the user never changed gives way to the new default (an old fixed
  24-hour clock does not hold back a new "Automatic"); the app records what each version ships for the next upgrade
  and knows what Deskset 0.1 shipped. A root config the app no longer ships is left as it is: Deskset 0.1's example
  skins (root config `Deskset`) stay in the Skins folder, and on the desktop, of someone who had them. On the very
  first launch (no skin has any saved settings yet) the skins listed in `FirstRun.ini` next to the default skins load,
  in the order written, each at `X`, `Y` points from the top-left corner of the main display's visible area (below the
  menu bar, beside the Dock) and with the .ini named by `File`: the Clock and the Calendar (small), then the Weather
  and System (medium) under them, none of which asks for a permission. Without that file, or when none of its configs
  exists, the small Clock loads alone. The Manage window then opens on the first of them.
  `~/Library/Application Support/Deskset/Stationery.inc` (`#SETTINGSPATH#Stationery.inc`) is made at every launch
  when it is missing (never overwritten): `!WriteKeyValue` writes only into a file that exists, and the default
  widgets keep what the user types into them there (to-do items, cities…), outside the skins that upgrades replace.
- Why: product decision — a first desktop that asks for no permission, and settings and user content that survive
  upgrades.
- Skin impact: none for other skins; any skin may include `#SETTINGSPATH#Stationery.inc` and write into it.
- Status: emulated (`FirstRun.ini` and `Stationery.inc`: Deskset extensions)

### Restart and Focus (Rainmeter 5.0)
- Windows (Rainmeter): Shift changes Exit to Restart in the application context menu and Refresh skin to Focus skin
  in a skin context menu. `!Restart` and `Rainmeter.exe /Restart` restart the application. Focus brings a skin forward
  within its current z-position (<https://www.rainmeter.net/changes-5.0/>).
- Mac (Deskset): the context menus use native Shift alternates, Restart Deskset and Focus Skin, without adding a
  keyboard shortcut. The standard application Quit shortcut remains Command+Q. `!Restart`, `Deskset '!Restart'`
  and `Deskset /Restart` share the ordinary save-and-quit checks; a skin's request waits until its current action
  finishes. A private helper opens the same application only after authorization and the exact old process's exit.
  Cancelling a save, failed preparation, a replaced PID or a timeout never authorizes a launch. Update installation
  and restart handoffs exclude each other, including callbacks during a save modal. Normal shutdown saves the
  existing desktop and application state; no persistent restart flag is added. Failures are written to the log.
  A command with no running instance starts Deskset once rather than entering a restart loop.
  Focus waits for the selected instance to finish loading, consumes earlier pending restacks, and brings that
  visible window forward at its existing level. It does not change its frame, LoadOrder, settings, key window or
  application activation. Hidden, stopped, retired and replaced instances are left alone; a skin-menu action
  addresses only the clicked instance. Later explicit load-order or window changes may restack normally.
- Why: process exit must finish before a fresh desktop starts; focus must preserve the running skin.
- Skin impact: restart retains the saved desktop; focus does not reset measures or run a refresh.
- Status: emulated / partial. Windows behavior for a restart command with no current process, save/preparation
  failures, hidden skins and multi-selection Focus remains unverified. The legacy `RestartRainmeter.exe` helper is
  not mapped on macOS. Direct checks of native modifier-menu display remain incomplete.

### Safe Start
- Windows (Rainmeter): the 5.0 changes specify holding Control+Shift for one second during startup, and an offer
  after two crashes within five minutes. Recovery saves the previous desktop as `@Backup` and loads the bundled
  default layout without removing skins (<https://www.rainmeter.net/changes-5.0/>,
  <https://docs-v5.rainmeter.net/manual/user-interface/>). The older Control-only wording on the interface page
  predates the updated shortcut.
- Mac (Deskset): the primary desktop instance samples Control+Shift while startup observation is prepared; a
  completed hold remains eligible if that preparation takes longer. The two triggers share one native offer.
  Safe Start saves `@Backup` before atomically committing an empty desktop, then loads the available exact variants
  from Deskset's bundled first-run layout. Skin files are retained; application preferences and global options are
  preserved.
  Default window settings apply on first load, and layout positions apply before the windows appear in all executor
  modes. Cancel continues ordinary startup without changing the layout or `@Backup`. Backup or state-write failure
  stops startup; the previous skins are not loaded as a fallback. An accepted recovery takes precedence over a layout
  supplied at launch. Missing default variants are skipped; an unavailable default layout leaves an intentional
  empty desktop and a warning, without the ordinary first-launch Clock fallback.
- Why: a separate same-user process observes the primary process's actual kernel exit status. ABRT, TRAP, SEGV, BUS,
  ILL and FPE exits count; normal exits (including nonzero exit codes), TERM, KILL and missing results do not.
  Startup uses verified results in a rolling five-minute window, excluding future timestamps and clock anomalies.
  Unknown or unavailable observation produces a warning without inventing a crash; manual recovery remains usable.
- Skin impact: a broken startup skin can be replaced by the default desktop while its files and saved backup remain.
- Status: emulated / partial. Exact Windows prompt wording, button focus, cancellation, counter-clearing policy,
  startup-command precedence and missing-default handling remain unverified. Observation starts after the primary
  instance is acquired; failures before the observer is ready and unavailable exit results cannot be counted.
  Automatic crash dumps are separate and remain unsupported.

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

### A loaded skin that is hidden (Manage window)
- Windows (Rainmeter): the Manage window lists the active skins with their Coordinates, Position, Load order,
  Transparency and other settings (https://docs.rainmeter.net/manual/user-interface/manage/); the manual does not
  describe any sign there that a skin is hidden by `!Hide` or StartHidden. `!Show` shows it again.
- Mac (Deskset): a loaded skin hidden by a skin action (`!Hide`, `!HideFade`, `!Toggle`, their group forms, a bang
  from another skin) or by StartHidden is marked: its row has a crossed-out eye, its status reads "Loaded, hidden",
  and a notice says that it is loaded and running but off the desktop, with a Show button that shows it as
  `!ShowFade` does (the row's menu has Show too). Typing coordinates for a hidden skin moves it out of sight, and a
  hint under the coordinates says it is still hidden. The window looks for skins hiding and showing themselves twice a
  second while it is on screen. Show changes no setting: a skin that hides itself can hide again (the Stationery
  Spectrum strip with Hide When Idle, the next time it goes quiet), and StartHidden hides it again at its next load.
- Why: a skin that hid itself (for example while it has nothing to show) looked lost: its window and its menu were
  gone, and moving it did not bring it back.
- Skin impact: none.
- Status: Mac-only UI

---

## Config and app bangs

### Skin aliases and Group selectors (Rainmeter 5.0)
- Windows (Rainmeter): the [5.0 command rules](https://www.rainmeter.net/changes-5.0/#bangs-and-command-line-arguments)
  provide config aliases and skin selectors that can match several groups.
- Mac (Deskset): `!Skin:Load`, `Unload`, `Toggle` and `Edit` reach the existing config and editor operations.
  `!Skin:Unload *` unloads all running skins. Commands on loaded skins accept `Group=a|b` (either group) or
  `Group=a&b` (both); a mixed expression matches nothing. Snapshot and live matching agree, and each selected skin
  receives the command once in load order. A command addressed to a loading config still waits for that load;
  retired skins cannot send late commands into a replacement layout. Window commands, variables and options share
  these selectors, preserving magic-quoted values while forwarding.
- Why: aliases and selectors reuse the existing lifecycle and executor boundaries.
- Skin impact: Toggle changes activation rather than visibility; `!Toggle` retains its original meaning.
- Status: emulated. Group loading, group toggling and group editing are not added; their Windows behavior remains
  unverified. Existing classic command behavior is retained.

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
- Windows (Rainmeter): the 5.0 changes specify that activating a loaded skin brings it forward at its current
  z-position (<https://www.rainmeter.net/changes-5.0/>). Without File, the next INI variant is still selected.
- Mac (Deskset): selecting the running variant focuses that instance without reloading, updating or warning.
  File names are compared ignoring case. The existing missing-file fallback and next-variant selection remain;
  another variant replaces the running one. Refresh, ToggleConfig, Manage and ordinary variant menus retain their
  existing load behavior.
- Why: repeated activation must not reset measures or repeatedly reload a skin that activates itself.
- Skin impact: use `!Refresh` when a reload is required.
- Status: emulated; see Restart and Focus for the window-ordering limits.

### !RefreshApp and Refresh All
- Windows (Rainmeter): refreshes Rainmeter and all skins.
- Mac (Deskset): re-reads the Skins folder, decodes images again, reads every known `@Resources/Fonts` folder again
  (added, replaced and removed fonts) and refreshes every skin. The app itself is not restarted.
- Why: —
- Skin impact: none.
- Status: emulated

### Layouts: !LoadLayout
- Windows (Rainmeter): [Manage → Layouts](https://docs.rainmeter.net/manual/user-interface/manage/#LayoutsTab)
  saves config settings. A normal load preserves selected old global options and applies other target options;
  it saves `@Backup` after close actions. Loading `@Backup` keeps it unchanged and ignores its wallpaper.
- Mac (Deskset): Manage Save/Load/Delete/Edit and its three save options, the status-menu list, `!LoadLayout`,
  `!Manage Layouts`, their executable command forms and installer application are implemented. The exchange format
  is `Layouts/<name>/Rainmeter.ini`; empty layouts have zero-byte INIs and disable the other save options. Overwrite
  requires confirmation, `@Backup` cannot be saved manually, and Delete moves the folder to the Trash. A save with
  no new wallpaper preserves the old picture and other folder files. State.json stays internal. See [Layouts](layouts.md)
  for close-action ordering, Active indices, section-order ties, positions/anchors and wallpaper mapping.
- Why: per-config settings map to macOS. Raw Windows global and `[TrayMeasure]` values are preserved and merged on
  normal loads or restored from `@Backup`; unsupported global/tray behavior remains unsupported. Local app preferences
  stay separate and unchanged. Windows filename
  enumeration varies by filesystem; Deskset's alphabetical order is deterministic but not a universal sorting match.
- Skin impact: compatible suites can load their installed layouts. A layout does not contain skin files or make
  an unsupported plugin work. The implementation has not been verified on a Windows desktop.
- Status: emulated / partial (global settings, wallpaper and filename portability)

### Other host bangs
- Windows (Rainmeter): `!SetClip`, `!SetWallpaper`, `!Play` / `!PlayLoop` / `!PlayStop`, `!Manage`, `!About`,
  `!EditSkin`, `!Quit`, `!Restart`, `!ResetStats`, `!SetAnchor`.
- Mac (Deskset): `!SetClip` sets the pasteboard; `!SetWallpaper` sets the desktop picture of every display (Tile shows
  the picture unscaled like Center: macOS cannot tile); `!Play` plays one sound at a time; `!Manage` opens the Manage
  window on the named config; `!Debug Log` opens the log; `!About` opens version information; `!EditSkin` opens the file in the text editor; `!Quit` quits
  after the current action. `!ResetStats` clears cumulative network statistics on the owning executor; `!SetAnchor`
  changes the window anchor while preserving its position expressions.
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
  configs and whether they replace (backed up) or add to installed ones; layouts and the apply-included-layout option; fonts the
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
  If applying an included layout, all old skins close before files are replaced. Their post-close settings form
  `@Backup` using the old variant list, then the shared layout coordinator applies the installed layout without a
  process restart.
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
  Missing folders on the IconPath are created. A symbolic link or Finder alias is followed first, so its icon is the
  original's, without Finder's arrow (see "Icons of links and aliases" in `plugins.md`).
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
  | AudioLevel `Port=Output`, AppVolume peaks (macOS 14.2+) | Screen & System Audio Recording → System Audio Recording Only (AudioLevel: asked the first time another app plays sound while the skin is loaded) | `NSAudioCaptureUsageDescription` | levels read 0; AudioLevel `MacPermission` 1 once the silence watchdog suspects it |
  | AudioLevel `Port=Output` (macOS 13 – 14.1) | Screen Recording (then restart Deskset) | — | levels read 0 |
  | AudioLevel `Port=Input` | Microphone | `NSMicrophoneUsageDescription` | levels read 0 (tried again every 10 s) |
  | NowPlaying / iTunes / WebNowPlaying, RecycleManager Empty, FileView Properties | Automation (Music, Spotify, Finder) | `NSAppleEventsUsageDescription` | player shown as closed; Trash / Get Info do nothing |
  | WiFiStatus SSID and LIST; MacWeather / MacSun `Location=auto` | Location Services (asked once per launch at most, reduced accuracy) | `NSLocationUsageDescription`, `NSLocationWhenInUseUsageDescription` (one text for both: weather and sun, then Wi-Fi names) | names empty; weather `Status` 5 |
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
  looks 10 seconds apart while the same app was playing sound, and no system-audio stream had carried sound since
  Deskset started (the usual sign of a refused System Audio Recording permission, which macOS reports as silence;
  AudioLevel's `MacPermission` then reads 1); Location Services are off for a WiFiStatus SSID / LIST measure or a
  MacWeather / MacSun `Location=auto` measure (the weather note is taken back at the measure's next update once they
  are allowed); Deskset
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
  [--appearance light|dark|system] [--dark] [--clock-hours 12|24|system] [--first-weekday 0-6|system]
  [--temperature-unit C|F|system] [--clock ISO8601|UNIX] [--time-zone ID] [--seed N] [--wallpaper FILE] [--at X,Y]
  [--screen WxH|system] [--skins-dir DIR]` loads the skin without a window, runs N updates (default 2, 1 000 ms apart),
  draws it at scale S (default 2, at most 16 384 pixels a side) on a transparent or given background and prints
  compatibility notes and skin log lines. `--wallpaper` names a picture that stands in for the desktop picture, on a
  screen of `--screen` points (default 1512 × 982, a 14-inch MacBook Pro's; 1920 × 1080 with `--clock`) laid as macOS
  lays it by default (Fill Screen): Chameleon `Type=Desktop` samples it (a dynamic picture's light or dark one, as the
  appearance is), and the part under the skin is drawn behind it. `--at` puts the skin window's top-left corner there
  (default 0,0; `#CURRENTCONFIGX#`, `CropDesktop=Skin`). Without `--wallpaper`, `--background` stands in for a desktop
  of that one color, so a frameless skin picks the ink the image shows; with neither, Chameleon reads the Mac's own
  wallpaper. With a stand-in desktop the skin sees that one screen (`#SCREENAREAWIDTH#`…); in virtual time the
  wallpaper is read as a fixture. The skin sees the Light appearance (the appearance
  variables, SysColor) unless `--appearance dark` / `--dark` or `--appearance system` (the Mac's own setting), and a
  24-hour clock, weeks from Sunday and °C (`#MACCLOCKHOURS#`, `#MACFIRSTWEEKDAY#`, `#MACTEMPERATUREUNIT#` and the weather
  plugins' defaults) unless `--clock-hours`, `--first-weekday` or `--temperature-unit` give another value or `system`
  (the Mac's own). `--clock` runs the skin in virtual time from the given moment (ISO 8601, or seconds since 1970):
  update i is at that time plus i intervals and the monotonic clock steps with it; `!Delay`, ActionTimer steps,
  Bitmap transitions and plugin timers run at their own virtual times, and nothing waits in real time. Its time zone
  is UTC unless `--time-zone` names another (`--time-zone` alone changes only the zone). Background work comes back as
  ordinary work before the next update: local files (QuotePlugin, FolderInfo, FileView's listing, WebParser `file://`,
  RunCommand's OutputFile) are read or written as fixtures, the weather service is the preview and NowPlaying's
  position follows the virtual clock; work that reaches further (the network, programs, file icons, live system
  state) runs for real, gets up to one interval of real time to come back, and is listed on stderr as "not
  verifiable in virtual time". `--seed N` makes the skin's
  random numbers (Calc `Random` / `UniqueRandom`, QuotePlugin, WebParser's temporary file names, Lua `math.random`)
  the same in every run. There is no window: window, config and app bangs are accepted and ignored (Lua FadeWindow falls back
  to that ignored `!SetTransparency`), mouse actions never run, the Skins folder is the nearest ancestor named `Skins`
  (or `--skins-dir`). Nothing asks for a permission: nothing is captured, since only skins in skin windows capture
  (`DESKSET_AUDIO_DEMO=1` feeds a generated signal), players look closed (`DESKSET_NOWPLAYING_DEMO=1` fakes a playing
  track; `DESKSET_NOWPLAYING_DEMO=refused` a running Music that refused Automation), Location and Automation are never
  used. Fonts in `@Resources/Fonts`, FileView icons and the
  Registry `Wallpaper` value work as in the app.
- Why: repeatable screenshots without prompts or a visible screen.
- Skin impact: none (developer tool).
- Status: Deskset extension

### `--benchmark` (what a skin costs)
- Windows (Rainmeter): n/a.
- Mac (Deskset): `Deskset --benchmark Skin.ini… [--seconds N] [--warmup N] [--scale S] [--appearance light|dark]
  [--skins-dir DIR]` runs each skin without a window, one after another, from a temporary copy of its Skins folder: it
  updates at its own `Update` rate on the skin's clock, as in a skin window, and every update draws the window's
  picture as a skin window does (kept pictures of the meters that did not change included). After `--warmup` seconds
  (default 2) it measures for `--seconds` (default 10) and prints the updates, the time of an update and of a
  drawing, the pictures copied, made and the meters drawn per drawing, and the CPU time of the main thread and of the
  whole process per second, in percent of one core. What Core Animation and the window server do with the picture
  afterwards is not included. As with `--render`, nothing asks for a permission and no audio is captured:
  `DESKSET_AUDIO_DEMO=1` plays the demo signal into visualizers (its generator runs in the process, about 0.3 % of a
  core), `DESKSET_NOWPLAYING_DEMO=1` fakes a playing track. Window, config and app bangs are ignored, so a skin that
  switches its own tempo with `!Refresh` stays in the tempo it loads in.
- Why: comparing a skin's cost before and after a change without opening windows on the screen.
- Skin impact: none (developer tool).
- Status: Deskset extension

### `--system-report` and `--weather-report` (weather)
- Windows (Rainmeter): n/a.
- Mac (Deskset): `Deskset --system-report` ends with a Weather section when weather is set up on the Mac — an active
  skin writes a place in a MacWeather or MacSun measure, or Location Services are already allowed for Deskset: whether
  weather is on, the User-Agent, the units `Units=Auto` gives, the place table, the disk cache, the Location Services
  status (only the status: the report never reads the location and never makes macOS ask), and for each place in an
  active skin how it resolves offline and today's sunrise and sunset. Otherwise one line says weather is not set up.
  `Deskset --weather-report [--location PLACE|LAT,LON|timezone] [--units auto|metric|imperial]` makes one real request
  to MET Norway with the real User-Agent (default place: the sample "Oslo, NO"; `auto` is refused, the report never
  uses this Mac's location; `timezone` is the city of this Mac's time zone from the place table; nothing is read from or
  written to the weather cache) and prints the request, the response headers, now, the next hours, the days, the sun
  and the credit; exit status 0 with data, 1 without, 2 for a wrong argument.
  `--offline FILE [--now 2026-09-26T12:00:00Z]` reads a saved response instead (no network).
- Why: checking the weather setup and MET Norway's answers without a skin.
- Skin impact: none (developer tool).
- Status: Deskset extension

### MET Norway credit in the skin menu, weather settings
- Windows (Rainmeter): n/a.
- Mac (Deskset): the right-click menu of every skin with a MacWeather measure has "Weather: Based on data from MET
  Norway ↗" (opens api.met.no) and "Updated 12:05", after the skin's own items; the About window names MET Norway and
  GeoNames. `defaults write app.deskset.Deskset WeatherEnabled -bool NO` turns weather requests off (read at every
  use); `WeatherDebug -bool YES` adds the rounded coordinates of places written in skins (never this Mac's location)
  and timings to the log. See `weather.md`.
- Why: MET Norway's data is CC BY 4.0, and third-party skins may not credit it themselves.
- Skin impact: none.
- Status: Deskset extension

### Command-line flags
- Windows (Rainmeter): n/a.
- Mac (Deskset): the binary's development modes are `--render`, `--verify-drawing-cache`, `--benchmark`,
  `--self-test [filter]`, `--snapshot-ui`, `--system-report`, `--weather-report`, `--cover-lookup` and `--make-icon`;
  `--help` / `-h` prints them (exit status 0). An argument starting with `--` that is none of these flags or their
  options (`--out`, `--updates`, `--interval`, `--scale`, `--background`, `--skins-dir`, `--dark`, `--appearance`,
  `--clock-hours`, `--first-weekday`, `--temperature-unit`, `--clock`, `--time-zone`, `--seed`, `--wallpaper`, `--at`,
  `--screen`, `--select`, `--size`, `--zoom`, `--location`, `--units`, `--offline`, `--now`, `--seconds`, `--warmup`),
  or such an
  option without a mode, prints the usage to
  stderr and exits with status 2. Other arguments are left alone, so Finder / LaunchServices launches (`-psn_…`) and
  AppKit defaults (`-NSDocumentRevisionsDebugMode YES`) still start the app. (`--plist` belongs to
  `scripts/build-app.sh`, not to the binary.)
- Why: a mistyped development command (`--selftest`) used to fall through to the menu bar app, which then loaded and
  changed the user's real skins and settings.
- Skin impact: none (developer tool).
- Status: Deskset extension
