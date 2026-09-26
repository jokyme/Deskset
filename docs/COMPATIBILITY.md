# Deskset compatibility guide: how Rainmeter skins behave on a Mac

Deskset runs Rainmeter skins (`.ini`, `.rmskin`) natively on macOS. Most skins work without changes, but a Mac is
not Windows. This document lists **every place where a skin behaves differently on Deskset than in Rainmeter on
Windows**, why, and what a skin author or user can do about it.

It is compiled from the per-area notes in [`docs/compat/`](compat/) (engine, Lua, plugins, audio, media and UI,
installer, app) and from a re-test of 15 real skin packages (see
[Real-world test results](#12-real-world-test-results)). Everything is based on the public Rainmeter manual
(<https://docs.rainmeter.net/manual/>), public plugin READMEs, and observation of how skins behave. Deskset is an
independent clean-room implementation and does not contain Rainmeter code. The document describes Deskset as of
2026-09-24.

**Contents**

1. [How to read this document](#1-how-to-read-this-document)
2. [Support at a glance](#2-support-at-a-glance)
3. [The differences you are most likely to notice](#3-the-differences-you-are-most-likely-to-notice)
4. [macOS permissions](#4-macos-permissions)
5. [Plugin support matrix](#5-plugin-support-matrix)
6. [Engine: skins, meters, measures, drawing](#6-engine-skins-meters-measures-drawing)
7. [App, windows and bangs](#7-app-windows-and-bangs)
8. [Lua scripting](#8-lua-scripting)
9. [Bundled plugins (core)](#9-bundled-plugins-core)
10. [Audio, media, network and UI plugins](#10-audio-media-network-and-ui-plugins)
11. [WebParser and the skin installer](#11-webparser-and-the-skin-installer)
12. [Real-world test results](#12-real-world-test-results)
13. [Known gaps and what is planned](#13-known-gaps-and-what-is-planned)
14. [Sources and method](#14-sources-and-method)

A Simplified Chinese version of this document is in [`COMPATIBILITY.zh-CN.md`](COMPATIBILITY.zh-CN.md).

---

## 1. How to read this document

Every entry has the same five parts:

- **Windows** — what Rainmeter does, as documented in the manual (or observed in skins that are known to work).
- **Mac** — what Deskset does.
- **Why** — the macOS limitation, missing API, permission or judgment call behind the difference.
- **Skin impact** — what you will notice, and a workaround when there is one.
- **Status** — one of:

| Status | Meaning |
| --- | --- |
| **identical** | Works as the manual describes. Deskset may also accept a few things Rainmeter rejects ("leniencies"). |
| **emulated** | Same purpose and options, rebuilt on macOS equivalents. Numbers, wording or timing can differ in details. |
| **partial** | Some options or values work; the entry says which ones do not. |
| **not supported** | Has no effect. Values read `0` / empty, and the skin's *Compatibility Notes* (menu and Manage window) say so. A skin never crashes because of it. |
| **Mac-only** | A Deskset-specific safety limit or UI feature with no Rainmeter counterpart. |

"Judgment call" marks places where the manual is silent and Deskset had to choose a behaviour.

Where a skin is named as evidence, it is a third-party skin that was tested locally only; no third-party skin is
shipped with Deskset.

---

## 2. Support at a glance

| Area | Overall | What works | What does not (or differs most) |
| --- | --- | --- | --- |
| Skin files, variables, formulas, bangs | identical | INI rules, `@Include`, `#Var#` / section variables, formulas, `!SetOption` and the other skin bangs | Exotic PCRE regex features; Windows environment variables (`%APPDATA%`) in options |
| Layout and text | emulated | `r`/`R` positions, StringAlign, window sizing, inline options, fonts in `@Resources\Fonts` | Microsoft fonts are substituted; text can be a pixel wider or narrower |
| Meters (String, Image, Bar, Bitmap, Button, Line, Histogram, Roundline, Rotator, Shape) | emulated | All documented meter types and options | Histogram `PrimaryImageRotate` / ColorMatrix options |
| System measures (CPU, memory, network, disk, time, uptime, SysInfo, Process, battery) | emulated | All of them, mapped to macOS data | Drive letters all mean the startup disk; Windows adapter names fall back to the active interface |
| Registry | emulated (a fixed set) | Windows version, CPU / GPU name, core count, user folders, the wallpaper | Every other registry value reads `0` / empty |
| Lua (`Measure=Script`, inline Lua) | identical | Lua 5.1 and the whole SKIN / SELF / Measure / Meter API | `os.execute` only opens files and URLs; a few unsafe functions are removed |
| Rainmeter's bundled plugins | emulated | Every one except two (seven of them partly): ActionTimer, AudioLevel, NowPlaying, InputText, RunCommand, UsageMonitor, … | WindowMessage and VirtualDesktops have no macOS counterpart; temperatures / fans read 0 (no public sensor API) |
| Popular third-party plugins | 9 emulated or partial | WebNowPlaying, FrostedGlass, Chameleon, IsFullScreen, GetActiveTitle, SysColor, AppVolume, Mouse, Slider | Any other Windows DLL (PowershellRM, ActiveNet, MSI Afterburner, HWiNFO, …) |
| Installer | emulated | `.rmskin`, legacy Rainstaller packages, plain ZIPs, extracted folders, download ZIPs that wrap a `.rmskin`; fonts | `.rar` / `.7z`; Windows plugins and add-on programs are never installed; layouts are installed but not applied yet |
| Windows and window settings | emulated | Dragging, snapping, click-through, transparency, fades, all position bangs | Window levels are macOS levels; ⌘ instead of Ctrl; no DragGroup, no Aero blur, no stored anchors; layouts cannot be loaded yet |

---

## 3. The differences you are most likely to notice

1. **Temperatures, fan speeds, voltages and GPU clocks read 0.** macOS has no public API for hardware sensors
   (CoreTemp, SpeedFan, HWiNFO, MSI Afterburner values). CPU names and per-core loads do work.
2. **Drive letters (`C:`, `D:`, …) all show the startup disk.** Use `Drive=/Volumes/Name` for other volumes.
3. **Windows-only plugin DLLs do nothing** unless Deskset reimplements them (see the [matrix](#5-plugin-support-matrix)).
   Their parts of a skin stay empty; the skin keeps working.
4. **Music skins show Music.app or Spotify**, whatever player the skin was written for (WMP, foobar2000, AIMP,
   iTunes…), and whichever of them is playing.
5. **macOS asks for permission** the first time a skin needs system audio, the microphone, a player, Wi-Fi names
   or protected folders ([table](#4-macos-permissions)).
6. **Fonts:** Microsoft fonts (Segoe UI, Calibri, Consolas…) are replaced by close Mac fonts, so text may be
   slightly wider or narrower. Fonts shipped in the skin's `@Resources\Fonts` work as on Windows, and the installer
   also installs fonts that a package keeps next to its skins (a step Windows users do by hand).
7. **Commands that start Windows programs** (`.exe`, PowerShell, `cmd` built-ins, `wmic`) are not run. Portable
   and Mac command lines (`curl`, `date`, `open`) work in RunCommand; URLs and files open normally.
8. **Skin windows sit on the desktop by default** (Rainmeter's "On Desktop" level) and use macOS window levels.
9. **Old skins install directly:** legacy Rainstaller packages and plain ZIPs that Rainmeter 4 refuses are
   accepted, and fonts they carry are installed into the skin.
10. **Layouts are installed but not applied yet**, so a suite that arranges itself with a layout has to be
    loaded skin by skin for now.
11. **⌘ replaces Ctrl**: ⌘-drag moves any skin, and Control-click (the Mac's right click) opens the skin menu.

---

## 4. macOS permissions

Nothing is asked until a *loaded skin in the app* needs it. Previews, `--render` and the Manage window's
compatibility check never trigger a prompt. Deskset never asks for Accessibility (it uses it only if you have granted
it), and asks for Screen Recording only for audio visualizers on macOS 13 – 14.1.

| Feature (skin option) | macOS permission | When it is asked | If you refuse |
| --- | --- | --- | --- |
| AudioLevel `Port=Output` (visualizers), macOS 14.2+ | System Audio Recording ("Screen & System Audio Recording" → "System Audio Recording Only") | First time a visualizer skin runs | macOS delivers silence: levels read 0 and `DeviceStatus` still reads 1. If a visualizer stays silent for about 10 s while another app plays sound, the skin gets a compatibility note pointing to the permission |
| AudioLevel `Port=Output`, macOS 13 – 14.1 | Screen Recording, then restart Deskset | First time a visualizer skin runs | Levels 0, `DeviceStatus` 0, one log line |
| AudioLevel `Port=Input` | Microphone (orange indicator while capturing) | First time an input-level skin runs | Levels 0, `DeviceStatus` 0, one log line. Tried again every 10 s, so allowing it later works without a restart |
| AppVolume `NumberType=Peak`, AppVolume mute | System Audio Recording | First peak / mute use | Peak 0; mute has no effect |
| NowPlaying, iTunes, WebNowPlaying data and commands; MediaKey track keys without Accessibility | Automation → Music / Spotify | First poll of a *running* player, or first command sent to it | The player looks closed; commands do nothing. Re-checked every 30 s, so granting it later works without a restart |
| WiFiStatus `SSID`, `LIST` | Location Services (macOS shares Wi-Fi names only with such apps) | First time a skin with an SSID / LIST measure loads | SSID is empty and the list is empty; quality, rates and security still work |
| RecycleManager `EmptyBin` / `EmptyBinSilent`, FileView `Properties` | Automation → Finder | First use | Nothing is emptied / no Get Info window |
| RecycleManager `RecycleType=Size` | Full Disk Access (no prompt; set it in System Settings → Privacy & Security) | — | Size reads 0; a compatibility note and the log say where to grant it. `Count` needs no permission |
| Any skin file in Desktop, Documents, Downloads, removable or network volumes (Quote, FolderInfo, FileView, Lua `io`, images and other files a skin names) | Files and Folders | First access to that folder | Empty values, missing images; Lua's `io.open` returns nil and an error |
| MediaKey as real media-key events (volume HUD, any player) | Accessibility (never requested) | — | Track keys go to Music / Spotify through Automation; volume keys change the volume directly (no HUD) |
| GetActiveTitle window titles | Accessibility, or Screen Recording (never requested) | — | The frontmost app's name instead of the window title |
| WebParser or Ping reaching a device on your local network | Local Network | First such request | The request fails |

Win7Audio (volume, mute, output device), SysColor, IsFullScreen, Chameleon, CPU / memory / network / disk measures
and Slider's clicks anywhere on the screen (mouse events only; keys are never watched) need no permission. A refused permission (microphone, Screen Recording, System Audio Recording, Location, Automation,
Full Disk Access for the Trash size) and a MediaKey track key sent without Accessibility also show up in the skin's
*Compatibility Notes*, so users can see why a skin stays empty and where to fix it. Such a note goes away by itself
once it no longer applies: when the permission is granted later (Deskset notices within 30 seconds; Screen Recording
on macOS 13 – 14.1, and Full Disk Access when System Settings offers to quit and reopen Deskset, take effect only after
that restart) or, for the silent-visualizer note, as soon as sound arrives.

---

## 5. Plugin support matrix

`Plugin=Name`, `Name.dll` and `Plugins\Name.dll` are all accepted, in any case. Measures that "were previously a
plugin" (SysInfo, Process, WebParser, RecycleManager, MediaKey, NowPlaying, WiFiStatus) work in both forms. The
matrix covers every plugin on the manual's Plugins page (the deprecated ones included) and every `Plugin=` value used
by the 15 tested packages.

### Plugins and plugin-like measures bundled with Rainmeter

| Plugin / measure | Status | Notes |
| --- | --- | --- |
| ActionTimer | identical | Lists, Wait, Repeat, Execute, Stop; drift-free timing on the main run loop |
| AdvancedCPU (deprecated) | emulated | Per-process CPU time in Windows' 100 ns units; other users' processes are summed as one process named `System` |
| AudioLevel | emulated | Core Audio process tap (system audio) or input device; RMS, Peak, FFT, Bands; needs a permission |
| CoreTemp | partial | `Load` (per-core CPU) and `CpuName` work; temperatures, TjMax, voltage, power read 0; CPU speed 0 on Apple silicon |
| FileView | partial | Finder-like listing and icons; `ContextMenu` can only reveal the item in Finder |
| FolderInfo | emulated | Background scans; Mac hidden / system files |
| InputText | emulated | Native text field in a non-activating panel; works even on Stay Topmost skins |
| iTunes (deprecated `iTunesPlugin`) | identical | Reads and controls Music.app (or Spotify) |
| MediaKey | emulated | Real media keys with Accessibility; otherwise player commands and direct volume changes; `Stop` goes to the player |
| NowPlaying | emulated | Music.app and Spotify for every `PlayerName`; "whichever is playing" rule |
| PerfMon (deprecated) | partial | Common counters mapped to Darwin data; others read 0 |
| Ping (`PingPlugin`) | identical | Unprivileged ICMP echo on a background thread |
| PowerPlugin | emulated | Battery status; `Percent` 100 / `ACLine` 1 on Macs without a battery; `Hz` / `MHz` 0 on Apple silicon |
| Process | emulated | Mac process names (`.exe` dropped from ProcessName) |
| QuotePlugin | identical | Random line of a file or random file of a folder; Windows paths mapped to Mac folders |
| RecycleManager | partial | The Trash: `Count` works; `Size` needs Full Disk Access; emptying goes through Finder |
| Registry (measure) | emulated | A fixed set of machine facts answered with macOS values; everything else 0 / empty |
| ResMon | partial | `Handle` = open file descriptors; GDI / USER / Window read 0 |
| RunCommand | partial | Runs through `/bin/sh`; Windows-only command lines fail with error 103 before anything starts |
| Script (Lua) | identical | Lua 5.1.5, full SKIN API; see [§8](#8-lua-scripting) |
| SpeedFan | partial | Reads 0 until hardware sensor support exists |
| SysInfo | emulated | Mac answers for OS, user, screens, network adapters; a few Windows-only types read 0 / empty |
| UsageMonitor | partial | CPU, RAM, IO per process, per-core load, memory, paging, network, disks; GPU and exotic counters 0 |
| VirtualDesktops (older Rainmeter versions; not in the current manual) | not supported | One desktop is reported; commands ignored (macOS Spaces have no public API) |
| WebParser | identical | PCRE patterns translated to ICU; see [§11](#11-webparser-and-the-skin-installer) |
| WiFiStatus | emulated | CoreWLAN; SSID / LIST need Location Services; RXRate equals TXRate |
| Win7AudioPlugin | emulated | Default output device volume, mute, device switching; no permission |
| WindowMessage | not supported | macOS has no window messages; value 0, commands ignored |

### Popular third-party plugins

| Plugin | Status | Notes |
| --- | --- | --- |
| AppVolume | partial | App list and peaks (macOS 14.2+); per-app mute via a muted tap; per-app volume cannot be changed on macOS |
| Chameleon | emulated | Colors from the wallpaper or an image file with Deskset's own clustering (similar in spirit, not identical) |
| FrostedGlass | emulated | macOS vibrancy (NSVisualEffectView) behind the skin; not visible in `--render` images |
| GetActiveTitle | partial | Window title only with Accessibility / Screen Recording, else the app name |
| IsFullScreen | partial | Full-screen detection works; the process name is a Mac app name (`Safari`), never `chrome.exe` |
| Mouse | emulated | Actions on mouse input anywhere on the skin (drag sliders); a press is followed outside the skin until its release; RequireDragging Start / Stop; see §9.8 |
| Slider (the Mouse plugin's version 2) | emulated | ClickAction, DragAction, HoldAction, ReleaseAction and MoveAction for the left, right or middle button, on the skin and anywhere else on the screen (no permission needed); see §9.9 |
| SysColor | emulated | Windows color slots mapped to macOS semantic colors (accent, highlight, window, text…) |
| WebNowPlaying | partial | Shows Music / Spotify; the browser extension (web players) is not supported |
| Any other Windows plugin DLL (e.g. PowershellRM, ActiveNet, MSI Afterburner, HWiNFO) | not supported | Value 0 / empty, a compatibility note, the rest of the skin keeps working |

The installer lists the DLLs a package contains and warns that skins using unsupported ones will show missing
values.

---

## 6. Engine: skins, meters, measures, drawing

In short: skin files, variables, formulas and bangs follow the manual. Layout matches Windows at 100 % scaling.
The differences come from macOS itself (points instead of pixels, other fonts, no drive letters, no registry)
and from judgment calls where the manual is silent. Detailed notes: [`compat/engine.md`](compat/engine.md).

### 6.1 Layout and window size

#### Coordinates and units
- **Windows:** X, Y, W, H and font sizes are screen pixels at 96 DPI.
- **Mac:** one skin pixel is one macOS point. On a Retina screen everything is drawn at 2× (sharper, same layout).
  `#SCREENAREAWIDTH#`, `#WORKAREA…#` and SysInfo screen values are in points too.
- **Why:** macOS lays windows out in points; this keeps a skin the physical size it has on a typical Windows desktop.
- **Skin impact:** layouts match. Bitmaps are shown one image pixel per point, so low-resolution images look as
  soft as on a 100 % Windows display.
- **Status:** emulated

#### Relative positions (`r` / `R`) after aligned String and Bitmap meters
- **Windows:** `r` is relative to the previous meter's top/left edge, `R` to its bottom/right edge; StringAlign "is
  always based on the value of X or Y". Skins that work (eClock's long shadow, EasyInfo's LED digits, FluentDash11's
  settings rows) show that the next meter is placed from the aligned meter's *anchor* (its X / Y option).
- **Mac:** the same. `[Meter:X]` / `[Meter:Y]` still report the moved ("real") box, as the Section Variables page
  says. BitmapAlign follows the same rule (judgment call). A hidden meter has no size and is never moved.
- **Why:** the manual's anchor rule plus the authors' screenshots.
- **Skin impact:** right- and center-aligned stacks, shadows and label / value rows line up as on Windows.
- **Status:** identical

#### When the window size is computed
- **Windows:** with `DynamicWindowSize=1` the window is resized on every update; otherwise its size is fixed when
  the skin loads.
- **Mac:** without DynamicWindowSize the size is computed once, at the end of the first update, from every visible
  meter (content meters of a Container do not count) and the `BackgroundMode=0` image. A `!Redraw` run by a
  measure during the first update does not size the window early. `SkinWidth` / `SkinHeight` override the size.
- **Why:** as documented.
- **Skin impact:** a skin whose text grows after loading and that has neither DynamicWindowSize nor a fixed `W` is
  cut off, exactly as in Rainmeter. Example: a CPU text that loads as "CPU: 8%" and later shows "CPU: 21%".
  Add `DynamicWindowSize=1` or a `W`.
- **Status:** identical

#### Meter geometry before the first update
- **Windows:** not documented. The Lua main chunk runs "during the initialization phase of the skin" and
  Initialize() "during the first update cycle"; `Meter:GetX()` / `GetW()` are the meter's real position and size.
- **Mac:** meters are laid out at the end of the first update. Anything that asks for a meter's position or size
  earlier — a script's main chunk, Initialize() or first Update() (`GetX`, `GetW`, `SetX`…), or `[Meter:X]` /
  `[Meter:W]` read by measures in the first update — first gets a provisional layout computed from the meters' options
  (X / Y with `r` / `R`, W / H, Padding, Hidden, Container, image and shape sizes, and String meters' text with the
  bound measures' values at that moment). The provisional layout never sets the window size.
- **Why:** judgment call — the manual does not say when meter geometry exists; the options are known at load, so a
  layout from them is the closest meaningful value (before, every value was 0 until the end of the first update).
- **Skin impact:** scripts that store a meter's position or size in Initialize() get values from the options; a String
  meter bound to a measure has its real width only after the first update.
- **Status:** emulated

#### Background image size (`BackgroundMode=0`)
- **Windows:** "All general image options are valid for Background"; mode 0 shows the image at its size.
- **Mac:** the window is at least as large as the image after ImageCrop / ImageRotate (and EXIF orientation with
  `UseExifOrientation=1`). Judgment call: a skin that sets `Background=` without `BackgroundMode` gets mode 0 (the
  manual's default, 1, would make the option do nothing).
- **Why:** the window must hold what is drawn.
- **Skin impact:** none.
- **Status:** identical (+ one judgment call)

#### Container
- **Windows:** content is clipped by the container; containers cannot be nested.
- **Mac:** the same. `[ContentMeter:X]` is in skin coordinates (judgment call). An invalid `Container=` is a log
  line, not a compatibility note.
- **Why:** as documented.
- **Skin impact:** none.
- **Status:** identical

### 6.2 Text and fonts

#### Font size
- **Windows:** `FontSize` is in points at 96 DPI.
- **Mac:** size in points = FontSize × 96 / 72 (FontSize=10 draws 13.33-point text), so text takes the same room as
  on Windows at 100 % scaling.
- **Why:** macOS uses 72 points per inch; Rainmeter's sizes assume 96 DPI.
- **Skin impact:** none.
- **Status:** emulated

#### Font substitution
- **Windows:** FontFace names an installed family; Arial when it is missing.
- **Mac:** installed or skin-registered family first; then a table of Microsoft fonts macOS does not ship:
  Segoe UI (and its weights) → system font with Segoe UI's line metrics, Calibri → system font, Consolas / Lucida
  Console → Menlo, Cambria / Constantia → Georgia, Tahoma → Verdana, Century Gothic → Futura, Bahnschrift → DIN
  Alternate, Microsoft YaHei → PingFang SC, Meiryo / Yu Gothic → Hiragino Sans, Malgun Gothic → Apple SD Gothic Neo,
  …; then full / PostScript names ("Fira Sans Bold") and names with style words ("Roboto Light Italic"); finally
  Arial. Marlett's window-control letters map to Unicode symbols. Segoe MDL2 Assets / Segoe Fluent Icons glyphs
  have no Mac equivalent.
- **Why:** those fonts belong to Microsoft and are not on a Mac. Only Segoe UI's line metrics are copied.
- **Skin impact:** text can be a little wider or narrower, and `ClipString` may cut at a different character.
  Icon fonts from Windows show empty boxes. Ship the font in `@Resources\Fonts` to get identical text.
- **Status:** emulated (Windows icon fonts: not supported)

#### Skin fonts (`@Resources\Fonts`, `LocalFont`)
- **Windows:** fonts in the root config's `@Resources\Fonts` "are automatically loaded"; `LocalFontN=` loads more.
  Fonts elsewhere in a package must be installed by the user.
- **Mac:** the same files (`.ttf`, `.otf`, `.ttc`, `.otc`) are registered for Deskset only — never installed in macOS —
  before the skin measures any text. The folder is read again on every load, refresh, installation and Refresh All
  (added, replaced and removed fonts are picked up; a missing folder is looked for again after 5 s), and skins already
  on screen are measured again.
  The installer additionally copies fonts that a package keeps elsewhere into `@Resources\Fonts` (see
  [§11.2](#112-skin-installer)).
- **Why:** macOS registers fonts per process.
- **Skin impact:** fonts added to `@Resources\Fonts` are picked up by "Refresh skin". A skin's fonts are available
  to every other skin in Deskset (as on Windows), but not to other Mac apps.
- **Status:** identical

#### AccurateText
- **Windows:** `AccurateText=0` (default) measures text GDI+-style with extra padding; 1 uses tighter metrics.
- **Mac:** 0 adds 1/6 em of horizontal padding on each side (the commonly cited GDI+ value); 1 uses CoreText's
  advance width. Trailing whitespace is not counted unless `TrailingSpaces=1`. Sizes are rounded up to whole pixels.
- **Why:** the exact GDI+ padding is not documented.
- **Skin impact:** String meters may be a pixel or two wider or narrower than on Windows.
- **Status:** emulated

#### Empty String meters
- **Windows:** since 3.0 a String meter with an empty string has no size.
- **Mac:** the same, except when the text is empty only because its measure has no data *on the Mac* (a Windows-only
  plugin, a registry value that is not emulated, a SysInfo type without a Mac answer): then the meter keeps the
  height of one line.
- **Why:** on Windows the value would be there; letting those rows collapse would pile the rows below onto each other
  (seen in FluentDash11's CPU / GPU panels).
- **Skin impact:** rows below a missing value keep their spacing; genuinely empty strings behave as in Rainmeter.
- **Status:** identical (+ Mac-only rule for unavailable data)

#### Anti-aliasing, Angle, clipping and tabs
- **Windows:** `AntiAlias=1` smooths text; `Angle` rotates without changing size or position; ClipString 1 / 2.
- **Mac:** `AntiAlias=0` draws aliased (jagged) text, as the option asks. Judgment calls: Angle rotates around the
  StringAlign anchor, clockwise for positive radians, and the SolidColor background is not rotated; ClipString=1
  wraps only when both W and H are set; ClipString=2 also puts "…" on the last visible line; a single long word is
  clipped without "…"; tab stops every 4 × font size; a trailing newline adds no empty line.
- **Why:** the manual is silent on these details.
- **Skin impact:** skins without `AntiAlias=1` look harsher than users expect on a Mac.
- **Status:** emulated

#### Inline options (`InlineSetting`, `InlinePattern`)
- **Windows:** drawn by DirectWrite.
- **Mac:** every documented InlineSetting is drawn with CoreText. Judgment calls: CharacterSpacing's leading space
  before a line's first character is kept as an indent; a later span of the same kind wins where two overlap;
  GradientColor with "alternative gamma" interpolates in linear light; each match gets its own gradient box; inline
  Shadow is clipped to the meter.
- **Why:** CoreText and DirectWrite shape and space text differently in details.
- **Skin impact:** small spacing differences; Typography features depend on the Mac font having them.
- **Status:** emulated

### 6.3 Skin files, variables, formulas and options

#### Skin files (`.ini` / `.inc`, `@Include`)
- **Windows:** case-insensitive section and key names, `;` comment lines, quotes around a value ignored, a repeated
  section ignored, `@Include` merges a file as if pasted, relative paths from the skin folder.
- **Mac:** the same. Judgment calls: one pair of matching quotes (`"` or `'`) around a whole value is removed; a key
  repeated in one section of one file: the first wins; an `@Include` before any section is ignored with a warning;
  a missing include file is also looked for next to the including file and case-insensitively; `\` paths work;
  encodings UTF-8 / UTF-16 / UTF-32 (with or without BOM where detectable), otherwise Windows-1252; an unterminated
  `[Name` line is a section header; include limits 30 levels, 500 files, 32 MB per file. `!WriteKeyValue` quotes
  values with leading / trailing spaces and turns line breaks into spaces; it only writes files under `#SKINSPATH#`
  or `#SETTINGSPATH#`, as documented.
- **Why:** the manual does not describe these edge cases; the fallbacks only apply when a file would otherwise be
  missing.
- **Skin impact:** none for valid skins.
- **Status:** identical (+ leniencies)

#### Section variables in options without DynamicVariables
- **Windows:** "Section variables are always dynamic"; DynamicVariables=1 is needed to *update* them. The manual
  does not say what a non-dynamic option does with `[Name]`; skins that work (HDD Usage Bars, Mini Weather,
  HMNmeter2) show that it is resolved once and then kept.
- **Mac:** a section without DynamicVariables whose options name a measure or meter reads them once more when the
  first update reaches it (after the measures above it were updated and the meters above it were placed), and
  again after a `!SetOption` on it. This includes `MeterStyle` (`MeterStyle=StyleButton[MeasureState]`). A `[Name]`
  that names no section stays as written. Values that depend on section variables (a MeterStyle name, a Calc
  `Formula` or `IfCondition` naming a meter) are checked, and logged if wrong, only once they have resolved.
- **Why:** the evidence above; at load time there are no measure values or meter positions yet (judgment call on
  the exact moment).
- **Skin impact:** layouts that use `[Meter:X]` / `[Meter:W]` without DynamicVariables line up as on Windows; a
  measure value is its first value (Simple Clean's greeting shows the user name), and values meant to change still
  need `DynamicVariables=1`, as in Rainmeter.
- **Status:** emulated

#### Variables (details)
- **Windows:** `#Var#`, `[#Var]`, escapes `#*Var*#` / `[*Name*]`, character variables `[\x263A]` for
  x0–xFFFE, `[M:]` with up to ten decimals.
- **Mac:** the same, plus: character variables accept any Unicode code point (emoji) and an upper-case `X`; a
  variable's value is scanned again where it is used (so `!SetVariable V "[MeasureCPU]"` behaves as text
  substitution); `#Var#` is resolved before section variables; `[M:%]` is clamped to 0–100; `[M:/N]` accepts any
  non-zero divisor; numbers are rounded half away from zero; `:EscapeRegExp` and `:EncodeURL` use exactly the
  manual's character sets. Windows environment variables (`%APPDATA%`) are **not** expanded in ordinary options
  (plugins and Lua map the common ones, see [§9](#9-bundled-plugins-core) and [§8](#8-lua-scripting)).
- **Why:** judgment calls where the manual is silent; macOS draws every Unicode plane.
- **Skin impact:** none for valid skins.
- **Status:** identical (+ leniencies)

#### Formulas
- **Windows:** the operators and functions of the Formulas page; precedence is not documented; `.5` must be written
  `0.5`; `&&` / `||` operands "must" be in parentheses; `?:` nests at most 30 deep.
- **Mac:** C-like precedence (lowest to highest: `?:`, `||`, `&&`, `= <>`, `< > <= >=`, `|`, `^`, `&`, `+ -`,
  `* / %`, unary `- + ~`, `**`). Division or modulo by zero and non-finite results give 0; `%` is C `fmod`;
  `Round(x)` rounds half away from zero; `Min` / `Max` take more than two arguments. Leniencies: `.5`, `5.`, `1e3`,
  lower-case `0b` / `0o` / `0x` prefixes in every formula, `&&` / `||` without parentheses, `==`, no nesting limit;
  a plain number option reads its leading number (`12px` → 12).
- **Why:** a formula must never crash or return NaN; judgment calls where the manual is silent.
- **Skin impact:** none for valid formulas; some formulas Rainmeter rejects work on the Mac.
- **Status:** identical (+ leniencies)

#### Hex colors with a `0x` prefix
- **Windows:** the manual documents `RRGGBB[AA]` and `R,G,B[,A]` only.
- **Mac:** `0xRRGGBB` / `0xRRGGBBAA` (`0x` or `0X`) are accepted too.
- **Why:** judgment call — skins in the wild write every color this way (EasyInfo), so their authors evidently saw
  working colors.
- **Skin impact:** such skins show their intended colors.
- **Status:** emulated

#### Misspelled and legacy option names
- **Windows:** not documented, but skins that work use `ValueReminder` for `ValueRemainder` on Roundline / Rotator
  (Enigma's clocks, Elegant Watch) and their hands move.
- **Mac:** `ValueReminder` is accepted wherever `ValueRemainder` is (the correct spelling wins when both are set);
  the Image meter's deprecated `Path` works. Other misspellings (`GrayScale`, `Substitue`) are not aliased because
  nothing shows Rainmeter accepts them.
- **Why:** observed behaviour of working skins.
- **Skin impact:** analog clocks written with the misspelling move their hands.
- **Status:** identical (by observation)

#### Number formatting (NumOfDecimals, AutoScale, Scale, Percentual)
- **Windows:** AutoScale `0`, `1`, `1k`, `2`, `2k` with units k, M, G; a consistent space before the unit.
- **Mac:** units k, M, G, T; `1m` / `1g` / `1t` / `2m` / `2g` / `2t` accepted as an extension; the space is always
  added, even without a unit (`Text="%1 %"` with AutoScale shows "96.2  %"); the unit is chosen from the unrounded
  value; Scale with a decimal point shows 1 decimal unless NumOfDecimals is set; Percentual clamped to 0–100;
  printf rounding (2.5 → "2"); NumOfDecimals limited to 0–30.
- **Why:** judgment calls where the manual is silent (not verified against Windows).
- **Skin impact:** an AutoScale value may differ by a space or a last-digit rounding.
- **Status:** emulated

#### Time and Uptime formats
- **Windows:** strftime codes with the `#` flag; value = seconds since 1601; Uptime `%1`…`%4` with printf specs;
  FormatLocale uses Windows locale data.
- **Mac:** the same codes. Judgment calls: `%r` is upper-case "10:55:03 PM"; `%Z` is the English zone name; unknown
  codes are shown as written; an empty Format means `%H:%M:%S`; with Format set, the number is the leading number
  of the text; TimeZone accepts fractional hours and is not applied to TimeStamp values (numeric ones included);
  TimeStamp parsing is lenient; AddDaysToHours defaults to 1. Locale formats (`%c`, `%x`) come from macOS (ICU) data.
  FormatLocale / TimeStampLocale understand Windows' three-letter language codes (`DEU`, `CHS`…) and `Language_Country`
  names from a built-in table of common locales.
- **Why:** macOS locale data; the manual is silent on the details.
- **Skin impact:** localized dates may be spelled slightly differently (e.g. a two-digit year in German `%c`); a rare
  Windows locale name that is not in the table uses the default locale.
- **Status:** emulated

#### Actions, bangs, Substitute and regular expressions
- **Windows:** `[!Bang arg "arg"]`, magic quotes `"""…"""`, legacy `!Rainmeter…` names; Substitute and
  RegExpSubstitute use PCRE.
- **Mac:** the same syntax; bang names are case-insensitive; brackets inside quotes do not end a bang; text between
  bracketed bangs is ignored; `!Execute` nesting stops after 8 levels. Plain substitution is case-sensitive;
  `'a':'b'` is accepted (the manual says it fails). Regular expressions are PCRE patterns translated to ICU: `(?U)`,
  lookarounds and named groups work; `(?|…)` renumbers groups, `\K` is dropped, conditionals become plain
  alternatives, recursion is not supported; `\w`, `\d` and `(?i)` are Unicode-aware; `.` and `$` also treat `\r` as
  a line end; each regex operation stops after 1 second of CPU time (at most 10 seconds on a busy Mac).
- **Why:** macOS has ICU, not PCRE.
- **Skin impact:** common patterns such as `(?siU)<tag>(.*)</tag>` behave the same; exotic PCRE features may not
  match.
- **Status:** identical (common patterns) / partial (exotic PCRE)

#### Update interval and Counter
- **Windows:** `Update` minimum 16 ms, -1 = once; Calc's `Counter` only resets when the skin is unloaded.
- **Mac:** the same.
- **Why:** as documented.
- **Skin impact:** none.
- **Status:** identical

#### Compatibility notes shown to users
- **Windows:** errors and warnings go to the log.
- **Mac:** the *Compatibility Notes* (menu and Manage window) list only things that work differently on the Mac:
  Windows-only measures and plugins, unsupported bangs, registry values and SysInfo types without a Mac answer,
  unsupported Histogram image options, WebParser certificate flags, and — in the app — refused permissions, players
  without a Mac version and the WebNowPlaying browser extension (see [§4](#4-macos-permissions)). A permission note
  goes away by itself once the permission is granted. Mistakes in the skin itself (a missing MeterStyle, an invalid
  Container, a misspelled bang or measure type) are log lines only.
- **Why:** a skin's own mistakes behave the same in Rainmeter and are not a Mac difference.
- **Skin impact:** fewer, more relevant notes; authoring warnings are still in the log.
- **Status:** Mac-only

### 6.4 Measures

#### Measures that "were previously a plugin"
- **Windows:** SysInfo, Process, WebParser, RecycleManager, MediaKey, NowPlaying and WiFiStatus still work as
  `Measure=Plugin` + `Plugin=Name` (`Name.dll`, `Plugins\Name.dll`).
- **Mac:** both forms work; plugins implemented by Deskset are found either way.
- **Why:** as documented.
- **Skin impact:** old skins in plugin syntax work without a note.
- **Status:** identical

#### CPU
- **Windows:** 0–100; `Processor=0` all cores, N core N.
- **Mac:** Mach host statistics (user + system + nice). Cores are the Mac's logical cores (performance and
  efficiency cores on Apple silicon, no hyper-threading). The very first reading is the average since boot, then
  per-interval usage.
- **Why:** macOS source of CPU load; a first reading of 0 made fixed-size skins too narrow.
- **Skin impact:** per-core graphs show the Mac's core count.
- **Status:** emulated

#### Memory, PhysicalMemory, SwapMemory
- **Windows:** PhysicalMemory = RAM, SwapMemory = page file, Memory = RAM + page file ("commit charge").
- **Mac:** macOS swap stands in for the page file: PhysicalMemory = RAM (used = app + wired + compressed memory,
  Activity Monitor's "Memory Used"); SwapMemory = RAM + swap; Memory = both added (total = 2 × RAM + swap).
  `Free=1` gives total − used. MaxValue is automatic.
- **Why:** macOS has no fixed-size page file; the manual's definitions are followed literally.
- **Skin impact:** Mac users may expect SwapMemory to be swap only; Memory / SwapMemory percentages have no Activity
  Monitor counterpart.
- **Status:** emulated

#### NetIn / NetOut / NetTotal
- **Windows:** bytes per second; `Interface` = Best (default), 0 = all, N or an adapter name.
- **Mac:** Best = the active interface (wired before Wi-Fi); 0 = all active interfaces except VPN tunnels, AWDL,
  bridges and similar virtual ones (no double counting); a Windows adapter name (`Wi-Fi`, `Realtek PCIe GBE…`) or an
  index that does not exist falls back to Best (logged once). `Cumulative=1` counts since boot; no statistics are
  kept across restarts and `!ResetStats` is not supported.
- **Why:** macOS interface names (`en0`) differ from Windows adapter names.
- **Skin impact:** skins that name a Windows adapter measure the active Mac interface.
- **Status:** emulated

#### FreeDiskSpace
- **Windows:** `Drive=C:`; Total, Label, Type, IgnoreRemovable.
- **Mac:** every drive letter (`C:`, `D:`, `C:\`) is the startup volume `/`; a bare name (`Data`) means
  `/Volumes/Data`; absolute paths work. On APFS the numbers are the container's (as Finder shows). Type from the
  volume's properties (USB disks count as Fixed).
- **Why:** macOS has no drive letters.
- **Skin impact:** D:, E:, F: repeat the startup disk; write `Drive=/Volumes/Backup` for another volume.
- **Status:** emulated

#### SysInfo
- **Windows:** OS, user, network adapter, monitor and time-zone values.
- **Mac:** monitor values in points (monitor 1 = the primary screen), `SCREEN_SIZE` as "1920 x 1080", time-zone
  values with Windows sign conventions, OS values name macOS, `DOMAIN_WORKGROUP` is the SMB workgroup,
  `INTERNET_CONNECTIVITY` checks the default route (not the adapter in SysInfoData). Types without a Mac answer
  (`USER_SID`, `ADAPTER_GUID`) read 0 / empty with a compatibility note.
- **Why:** some types are Windows concepts.
- **Skin impact:** network adapter types need a Mac interface; monitor sizes are in points.
- **Status:** emulated / partial

#### Registry
- **Windows:** reads any registry value.
- **Mac:** there is no registry. Values skins commonly read for machine facts are answered with macOS equivalents
  (keys case-insensitive, `WOW6432Node` and `ControlSet00N` accepted): the Windows version keys under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (ProductName "macOS Tahoe", CurrentVersion, build numbers,
  RegisteredOwner…), WinSat `PrimaryAdapterString` (the chip name on Apple silicon, the graphics processor on an
  Intel Mac), `CentralProcessor\N` (ProcessorNameString,
  `~MHz` = 0 on Apple silicon), `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE`, `PROCESSOR_IDENTIFIER`, the computer
  name, `USERNAME`, `USERPROFILE` and the user shell folders (Desktop, Documents, Music, Pictures, Videos, Downloads).
  `HKCU\Control Panel\Desktop` `Wallpaper` is the path of the primary screen's current desktop picture ("" without a
  picture file), read again at every update. For a folder of rotating pictures macOS does not say which one is
  showing, so it is the folder's first picture by name (the one Chameleon samples too); the folder is looked into in
  the background, so the value stays empty until the measure's first update after that (a moment after the skin
  loads, or later for a measure that updates rarely, such as Enigma's `UpdateDivider=30`).
  Everything else reads 0 / empty and is listed once as a compatibility note. Video memory is not emulated on purpose:
  Apple silicon GPUs share the unified memory, so no number would mean the same thing.
- **Why:** a Mac answer is more useful than an empty row.
- **Skin impact:** version checks meant for Windows builds (`CurrentBuild >= 22000`) see a macOS build string
  such as "25F71", whose number value is 0. Skins that show video memory show 0. Wallpaper thumbnails (Enigma's
  layout options) show the desktop picture; with rotating pictures it may be another picture of the folder than the
  one on screen.
- **Status:** emulated (a fixed set of values)

#### Windows-only measures and plugins
- **Windows:** built-in Windows measures and third-party plugin DLLs.
- **Mac:** most are reimplemented (see the [matrix](#5-plugin-support-matrix)). Anything not provided — any other
  Windows DLL — reads 0 / empty, `!CommandMeasure` does nothing, and a compatibility note is shown. A String meter
  showing only such a value keeps one line of height.
- **Why:** Windows DLLs cannot run on macOS.
- **Skin impact:** those parts of a skin stay empty; the skin never crashes.
- **Status:** not supported (fallback)

#### Other measure details (judgment calls)
- **Windows:** the manual does not settle these.
- **Mac:**
  - Calc, Net, WebParser, Script and the core plugin measures whose values change, without MinValue / MaxValue,
    widen their range from 0…1 by the values seen (Measures → Percentage); `MaxValue=100` alone gives 0…100.
  - Order inside one update: value → range → average → invert → IfConditions → IfAbove / IfBelow / IfEqual →
    IfMatch → OnChangeAction → OnUpdateAction. IfAbove / IfBelow re-arm once the value leaves the range; IfEqual
    compares rounded values; an `IfAboveAction` without its `IfAboveValue` never fires.
  - Loop always moves from StartValue towards EndValue by |Increment|.
  - Time values are local wall-clock seconds since 1601, in whole seconds.
  - PowerPlugin: `Percent` 100 and `ACLine` 1 on Macs without a battery; `Lifetime` -1 / "Unknown" while unknown;
    `Hz` / `MHz` 0 on Apple silicon (no public CPU frequency).
  - Process: `.exe` is dropped from ProcessName; Mac process names often differ from Windows executable names.
- **Why:** judgment calls where the manual is silent.
- **Skin impact:** edge cases only (a constant Calc bound to a Bar needs MaxValue, as in Rainmeter).
- **Status:** emulated

### 6.5 Meters and drawing

#### Bound measures (`MeasureName`, `MeasureName2`…)
- **Windows:** `%1`, `%2`… are the values of MeasureName, MeasureName2…
- **Mac:** the same; a `MeasureName` that names no measure leaves slot 1 empty (it does not shift MeasureName2
  into it); `%N` is replaced in one pass.
- **Why:** as documented.
- **Skin impact:** none.
- **Status:** identical

#### Image files
- **Windows:** ".png is assumed" without an extension; png, jpg, bmp, gif, tif, webp, ico.
- **Mac:** the same, plus jpeg, jpe, dib, tiff and heic; a name whose extension is not an image type (a measure
  value like "12.5") also gets `.png` unless that exact file exists; files are re-checked on every use, so edited
  images show up without DynamicVariables; images larger than 8192 px per side are downsampled.
- **Why:** leniencies that cannot break a valid skin; the size cap bounds memory.
- **Skin impact:** none for normal images.
- **Status:** identical (+ leniencies)

#### Image options
- **Windows:** General Image Options; order of operations and color maths not documented.
- **Mac:** ImageFlip before ImageRotate (clockwise); crop and rotate after EXIF orientation; crop areas outside the
  image are transparent; ImageTint multiplies; Greyscale uses Rec. 601 weights; ColorMatrix replaces ImageTint /
  ImageAlpha (Greyscale still first); PreserveAspectRatio with only one of W / H follows the aspect ratio unless
  `PreserveAspectRatio=0` is written; masks keep the more transparent alpha; `UseExifOrientation=1` is honoured
  (default 0 = pixels as stored). Histogram's `PrimaryImageRotate` and ColorMatrix options are not supported
  (compatibility note).
- **Why:** judgment calls where the manual is silent; CoreGraphics scaling.
- **Skin impact:** tinted or greyscaled images may differ slightly in tone.
- **Status:** emulated / partial

#### Bar, Bitmap, Button
- **Windows:** documented on the Bar, Bitmap and Button pages.
- **Mac:** Bar fill lengths are whole pixels; BarImage is drawn at its own size and BarBorder ends are always drawn.
  Bitmap / Button strips are horizontal when the image is wider than tall; BitmapZeroFrame and transitions as
  documented; BitmapAlign like StringAlign. Button hit tests ignore transparent pixels; a Button's own mouse actions
  still run.
- **Why:** judgment calls where the manual is silent.
- **Skin impact:** none expected.
- **Status:** emulated

#### Roundline and Rotator
- **Windows:** several defaults and the modulo details are not documented.
- **Mac:** defaults StartAngle 0, RotationAngle 2π, LineStart 0, LineLength 0; ValueRemainder uses a floating-point
  modulo (hands move smoothly), negative values wrap, MinValue / MaxValue are ignored in that mode; no bound measure
  = 100 %; Solid with ControlStart / ControlLength draws a sector; Rotator images are drawn at their pixel size (not
  clipped to W×H) and always smoothed.
- **Why:** the manual's clock example only works this way; the rest are judgment calls.
- **Skin impact:** clock hands move smoothly when the value is fractional.
- **Status:** emulated

#### Line and Histogram
- **Windows:** documented on the Line and Histogram pages.
- **Mac:** GraphOrientation=Horizontal is the vertical graph turned 90° clockwise; history not yet filled reads as 0
  (a new graph starts as a flat line); without AutoScale the range runs from the lowest MinValue to the highest
  MaxValue (Line) or each measure's own range (Histogram); HorizontalLines draws 3 lines at the quarters;
  LineColor defaults to white; hidden meters keep sampling, and `!UpdateMeter` also adds a sample.
- **Why:** judgment calls where the manual is silent.
- **Skin impact:** a new graph starts flat instead of growing from one edge.
- **Status:** emulated

#### Shape
- **Windows:** Direct2D geometry.
- **Mac:** CoreGraphics. W / H from the stroked bounds rounded to whole pixels (matches the manual's screenshots);
  miter joins past the limit are beveled; dashes restart per figure; shapes are always anti-aliased; an empty
  required parameter counts as 0 (FluentDash11 writes `Rectangle ,,100,50,8`); `StrokeType` and a Combine `Consume`
  flag are accepted extensions; combined shapes' bounds are an upper bound. Gradient geometry, Arc sweep direction
  and transform anchors follow documented defaults with CSS / SVG-like choices where the manual is silent.
- **Why:** CoreGraphics instead of Direct2D.
- **Skin impact:** very sharp mitered corners and combined shapes can differ by a pixel.
- **Status:** emulated

#### Mouse hit areas
- **Windows:** fully transparent pixels of a skin are not clickable.
- **Mac:** meter rectangles catch the mouse (Shape: its solid parts; Button: its opaque pixels); clicks on fully
  transparent pixels pass to what is behind.
- **Why:** AppKit hit-tests borderless transparent windows by pixel alpha.
- **Skin impact:** a meter with an invisible `SolidColor=0,0,0,1` catches clicks, as on Windows.
- **Status:** identical

### 6.6 Actions and mouse

#### `!Delay`
- **Windows:** "the skin will be unresponsive" during the delay.
- **Mac:** the rest of the action runs later; the skin keeps updating; a refresh or unload cancels the pending part.
- **Why:** blocking would freeze every skin and the app.
- **Skin impact:** an update can run in the middle of a delayed action.
- **Status:** emulated

#### OnFocusAction, OnUnfocusAction, OnWakeAction
- **Windows:** run "at the very end of the update cycle".
- **Mac:** focus actions run when the focus changes (an `Update=-1` skin would never reach another update);
  OnWakeAction runs at the end of the first update after the Mac wakes (right away for `Update=-1`).
- **Why:** see above.
- **Skin impact:** none expected.
- **Status:** emulated

#### Formulas in bangs
- **Windows:** measures in a (formula) used in a bang do not need DynamicVariables.
- **Mac:** a `!SetOption` value that is one parenthesized formula naming measures is evaluated when the bang runs;
  Calc `Formula` / `IfCondition` set by `!SetOption` are stored as written; `!SetVariable` / `!WriteKeyValue`
  results keep up to 10 decimals.
- **Why:** judgment on the details.
- **Skin impact:** none expected.
- **Status:** identical

#### Variables (`#Var#`) in action options
- **Windows:** the Option Types page says that with `#VarName#` in an action option "the current value" is used; the
  Variables page says section variables in bangs are automatically dynamic and does not say the same of `#Var#`.
- **Mac:** `#Var#` in an action option (mouse actions, IfTrueAction, OnUpdateAction, FinishAction…) is replaced when
  the section's options are read — at load, after a `!SetOption` on the section, and at every update with
  `DynamicVariables=1`. Section variables (`[Measure]`), the nesting form `[#Var]` and escapes are resolved when the
  action runs.
- **Why:** judgment call where the manual's pages disagree.
- **Skin impact:** after `!SetVariable`, an action of a section without DynamicVariables still uses the old `#Var#`
  value. Set `DynamicVariables=1` on that section, or write `[#Var]`, which always gives the current value.
- **Status:** emulated (judgment call)

#### Keyboard modifiers and scrolling
- **Windows:** Ctrl overrides Draggable / SnapEdges while dragging; mouse wheel actions.
- **Mac:** ⌘ replaces Ctrl (Control-click opens the context menu on a Mac); scroll actions follow the physical
  direction (natural scrolling undone); a trackpad fires one scroll action per 24 points of movement, none during
  momentum. Details in [§7.2](#72-mouse).
- **Why:** macOS conventions.
- **Skin impact:** none.
- **Status:** emulated

#### Runaway actions
- **Windows:** no documented limit.
- **Mac:** actions that keep triggering each other stop after 20 000 steps per update or 16 nesting levels (logged);
  `!Update` inside an update is ignored.
- **Why:** a skin must never hang the app.
- **Skin impact:** only skins that would hang.
- **Status:** Mac-only

### 6.7 Safety limits

- **Windows:** the manual gives no limits.
- **Mac:** X, Y, W, H within ±1 000 000 points; skin windows at most 8192 points per side (16 384 in `--render`);
  String meter text cut at 32 768 UTF-16 units (4 096 inline ranges, 5 000 lines); FontSize 0…1000; images decoded
  at most 8192 px per side, ImageCrop sizes at most 32 768 px, images whose processed copy would exceed 16.7 million
  pixels drawn without their colour processing (tint, Greyscale, ColorMatrix); at most 500 distinct log-once
  messages and notes per skin and 256 pending `!Delay`s.
- **Why:** hostile or broken formulas must not exhaust memory or crash the app.
- **Skin impact:** none for real skins.
- **Status:** Mac-only

---

## 7. App, windows and bangs

Everything the menu bar app does around the engine: one borderless window per skin, window settings (Rainmeter keeps
them in Rainmeter.ini, Deskset in `~/Library/Application Support/Deskset/state.json`), mouse handling, menus, and the
window, config and app bangs. Details: [`compat/app.md`](compat/app.md).

### 7.1 Skin windows

#### Window levels (`AlwaysOnTop`, `!ZPos`)
- **Windows:** 2 Stay Topmost, 1 Topmost, 0 Normal (default), -1 Bottom, -2 On Desktop; skins other than Bottom stay
  visible when showing the desktop.
- **Mac:** macOS window levels. On Desktop = just above the Finder's desktop icons (still clickable and draggable);
  Bottom = below normal windows; Normal = the normal level; Topmost = the floating level; Stay Topmost = just below the
  menu bar (it covers the Dock). Every skin is on all Spaces. All positions except Bottom stay put during Show Desktop,
  Mission Control and Stage Manager; Bottom is hidden by them. Topmost and Stay Topmost also show over full-screen apps.
  Skins sharing a position are stacked by Load Order, then name.
- **Why:** macOS has window levels instead of Windows' Z-order bands.
- **Skin impact:** none intended; Stay Topmost skins cover the Dock.
- **Status:** emulated

#### New skins start On Desktop
- **Windows:** a config loaded for the first time starts at AlwaysOnTop=0 (Normal).
- **Mac:** it starts On Desktop (-2) unless the skin sets `DefaultAlwaysOnTop`.
- **Why:** product decision — Mac users expect widgets on the desktop, not over their documents.
- **Skin impact:** a newly loaded skin sits behind all windows; change it in the skin menu → Position.
- **Status:** emulated (judgment call)

#### `Default…` options in `[Rainmeter]`
- **Windows:** `DefaultWindowX/Y`, `DefaultAnchorX/Y`, `DefaultSavePosition`, `DefaultAlwaysOnTop`, `DefaultDraggable`,
  `DefaultSnapEdges`, `DefaultStartHidden`, `DefaultAlphaValue`, `DefaultOnHover`, `DefaultFadeDuration`,
  `DefaultClickThrough`, `DefaultKeepOnScreen`, `DefaultAutoSelectScreen` seed a config's settings the first time.
- **Mac:** the same, with state.json in place of Rainmeter.ini; positions accept the WindowX / WindowY forms (`%`,
  `R` / `B`, formulas, `@N`). The anchor is applied once, to place the skin (see Positions below).
- **Why:** —
- **Skin impact:** none.
- **Status:** identical

#### Dragging, `DragMargins` and the Ctrl override
- **Windows:** Draggable (default 1); a LeftMouseDownAction disables dragging; DragMargins limits where a drag can
  start; holding Ctrl overrides mouse actions and Draggable.
- **Mac:** the same rules; a drag starts after 3 points of movement. The override key is **⌘ (Command)**: ⌘-drag moves
  any skin and runs no click action; ⌘ while dragging inverts SnapEdges. The position is saved when the drag ends.
- **Why:** on the Mac, Control-click is the secondary (right) click.
- **Skin impact:** read-me files that say "hold CTRL" mean ⌘ on the Mac.
- **Status:** emulated

#### `DragGroup` (moving several skins together)
- **Windows:** skins of a DragGroup can be selected and dragged together.
- **Mac:** not supported; each skin moves on its own.
- **Why:** not implemented yet.
- **Skin impact:** grouped skins must be moved one by one.
- **Status:** not supported

#### SnapEdges and KeepOnScreen
- **Windows:** skins snap to screen edges and other skins; KeepOnScreen keeps a skin within the screen.
- **Mac:** snapping within 10 points of a screen edge (the full screen and the area below the menu bar / beside the Dock)
  or of a nearby skin. KeepOnScreen keeps the window on the screen it overlaps most, below the menu bar (the Dock area
  is allowed); a skin larger than the screen keeps its top-left corner visible. Even with KeepOnScreen off, a skin that
  ends up entirely off every screen (display unplugged) is brought back.
- **Why:** a window under the menu bar or off every screen could never be reached.
- **Skin impact:** none.
- **Status:** emulated

#### ClickThrough
- **Windows:** mouse detection off, clicks pass through; "Hold CTRL to temporarily disable".
- **Mac:** the window ignores the mouse entirely (no clicks, hover, tooltips or scrolling). The Ctrl / ⌘ override is
  **not** available, because macOS delivers no event to such a window. Turn it off from the skin's submenu in the menu
  bar menu or in the Manage window.
- **Why:** macOS window model.
- **Skin impact:** a click-through skin cannot be dragged, even with ⌘.
- **Status:** partial

#### AlphaValue, OnHover and fades
- **Windows:** AlphaValue 0…255; the menu offers 0 %…90 % transparency; OnHover 0 nothing, 1 hide, 2 fade in, 3 fade
  out; FadeDuration (default 250 ms) for OnHover and `!ShowFade` / `!HideFade` / `!ToggleFade`.
- **Mac:** the same. Judgment calls: OnHover=Hide also lets clicks pass through while the skin is hidden under the
  pointer (Fade out keeps its mouse actions); the pointer is polled every 100 ms so it also works for click-through
  skins; skins also fade in when loaded and fade out when unloaded (not on refresh); FadeDuration is clamped to
  0…10 000 ms.
- **Why:** the manual describes Hide and Fade out alike; a typo must not freeze a skin.
- **Skin impact:** none intended.
- **Status:** emulated

#### StartHidden
- **Windows:** the skin starts hidden; `!Show` shows it.
- **Mac:** the same (also from `DefaultStartHidden`); a hidden skin keeps updating and running its actions.
- **Why:** —
- **Skin impact:** none.
- **Status:** identical

#### Positions (`WindowX` / `WindowY`, SavePosition, `!Move`, `!SetWindowPosition`, AutoSelectScreen)
- **Windows:** pixel positions on the virtual desktop; SavePosition saves drags; `!SetWindowPosition` takes `%`,
  `R` / `B`, `@N` and anchors; a skin's anchor (`AnchorX` / `AnchorY`, `!SetAnchor`) is stored with its position.
- **Mac:** points with the origin at the top-left of the primary display (the one with the menu bar), y growing
  downward — the same convention, in points. `!Move` values are clamped to ±1 000 000. With SavePosition off the
  position lasts for the session. A new skin without a saved or default position is cascaded from the top-left of the
  visible area. AutoSelectScreen decides which display the monitor variables without `@N` describe. Anchors
  (`DefaultAnchorX` / `DefaultAnchorY`, the anchor arguments of `!SetWindowPosition`) are applied once, when the skin
  is placed; the saved position is always the window's top-left corner, and `!SetAnchor` is not supported.
- **Why:** macOS works in points (Retina); stored anchors are not implemented yet.
- **Skin impact:** skins positioned for a specific Windows resolution land elsewhere on a Retina Mac; KeepOnScreen keeps
  them visible. A right- or bottom-anchored skin that changes size (DynamicWindowSize) grows to the right and down
  instead of around its anchor.
- **Status:** emulated / partial (stored anchors)

#### Display changes
- **Windows:** not described beyond KeepOnScreen and the monitor variables.
- **Mac:** when displays are connected, disconnected or rearranged, skins with a saved position are placed from it again
  (a skin returns to a display that comes back) and are kept on screen. Skins are not refreshed; the monitor variables
  change for sections with DynamicVariables=1.
- **Why:** judgment call; refreshing every skin would reset its state.
- **Skin impact:** a skin that computed its layout from `#SCREENAREAWIDTH#` without DynamicVariables keeps it until it
  is refreshed.
- **Status:** emulated

#### Sleep, displays asleep, other user sessions
- **Windows:** OnWakeAction runs "when Windows returns from the sleep or hibernate states".
- **Mac:** while the Mac sleeps, the displays sleep or another user's session is in front, skin timers stop and so does
  audio capture (no recording indicator). They resume with an immediate update; after a real sleep OnWakeAction runs
  at the end of that update. Skins hidden with `!Hide` keep updating and keep their audio capture.
- **Why:** energy; macOS reports display sleep and session switches separately from system sleep.
- **Skin impact:** time-based measures jump forward after the pause.
- **Status:** emulated

#### Focus (`OnFocusAction` / `OnUnfocusAction`)
- **Windows:** the skin "receives focus" when clicked and "loses focus" when something else is clicked.
- **Mac:** skin windows never activate Deskset (the app in front stays in front). A skin window takes keyboard focus only
  when it has OnFocusAction or OnUnfocusAction; the actions run as soon as macOS reports the change (see
  [§6.6](#66-actions-and-mouse) for the timing). Typing into a focused skin is swallowed.
- **Why:** non-activating panels are what Mac widgets use.
- **Skin impact:** none intended.
- **Status:** emulated

#### Blur and BlurRegion (`[Rainmeter]`), blur bangs
- **Windows:** "Set to 1 to enable Aero Blur"; `!ShowBlur`, `!AddBlur`… change it.
- **Mac:** not supported (the FrostedGlass plugin is, see [§10.7](#107-window-desktop-and-color-plugins-third-party));
  the bangs add a compatibility note.
- **Why:** not implemented yet.
- **Skin impact:** the skin is drawn without the blurred backdrop.
- **Status:** not supported

### 7.2 Mouse

#### Right click and the skin menu
- **Windows:** right-click opens the skin menu unless a RightMouse…Action is set; Ctrl+right-click always opens it.
- **Mac:** the same rules; a Control-click (the Mac's secondary click) and ⌘+right-click always open the skin menu.
- **Why:** Mac conventions.
- **Skin impact:** none.
- **Status:** identical

#### Middle, X1 and X2 buttons
- **Windows:** Middle / X1 / X2 mouse actions.
- **Mac:** mouse buttons 3, 4 and 5 run them. Trackpads have no such buttons.
- **Why:** —
- **Skin impact:** none.
- **Status:** identical

#### Scroll actions
- **Windows:** MouseScrollUp/Down/Left/RightAction once per wheel notch.
- **Mac:** wheel notches map one to one. Trackpad scrolling runs one action per 24 points of finger travel (at most 10
  per event) and none during momentum. Directions are physical — fingers moving up is "up" whatever the Natural
  Scrolling setting.
- **Why:** Windows skins expect discrete notches; Natural Scrolling would otherwise flip every skin.
- **Skin impact:** scroll-driven skins (volume, lists) feel like on Windows.
- **Status:** emulated

#### Hover while a button is held
- **Windows:** not described.
- **Mac:** MouseOver / MouseLeave are not updated while a mouse button is held; they are reported when it is released.
- **Why:** the engine treats a hover update as the end of a press.
- **Skin impact:** none.
- **Status:** emulated

#### Cursors (`MouseActionCursor`, `MouseActionCursorName`)
- **Windows:** a hand over meters with mouse actions; MouseActionCursorName takes Windows cursor names or `.cur` / `.ani`
  files from `@Resources\Cursors`.
- **Mac:** HAND, TEXT, CROSS, NO, SIZE_WE and SIZE_NS map to macOS cursors; other names (HELP, BUSY, WAIT, PEN,
  SIZE_ALL, diagonal sizes, UPARROW) and custom `.cur` / `.ani` files show the arrow. A Button meter shows the hand;
  a meter whose only mouse actions are MouseOverAction / MouseLeaveAction does not (judgment call).
- **Why:** macOS has no public equivalents for those cursors; `.cur` / `.ani` are Windows formats.
- **Skin impact:** some skins show the arrow where Windows shows a custom cursor.
- **Status:** partial

#### Tooltips
- **Windows:** ToolTipText / ToolTipTitle, ToolTipIcon, ToolTipType (balloon), ToolTipWidth; ToolTipHidden in
  `[Rainmeter]`.
- **Mac:** standard macOS tooltips, one area per meter, the title on its own line above the text. ToolTipIcon,
  ToolTipType and ToolTipWidth are read but not shown. No tooltips for hidden meters, hidden containers' content,
  click-through skins or ToolTipHidden=1. `%1`, `%2`… in tooltips use the manual's forced format (AutoScale=1, no
  decimals) on every meter type (judgment call). Tooltips show whichever app is in front: skin windows allow them in
  the background (macOS otherwise shows a window's tooltips only while its app is active, and Deskset, a menu bar
  app, almost never is). They appear after half a second, as on Windows (AppKit alone waits two to three seconds).
- **Why:** macOS tooltips have no icon, balloon style or width setting.
- **Skin impact:** tooltips look like other Mac tooltips.
- **Status:** partial

### 7.3 Menus and the Manage window

#### Skin context menu and custom actions
- **Windows:** skin name, Variants, Settings (Position, Transparency, Hide on hover, Draggable, Click through, Keep on
  screen, Save position, Snap to edges…), Manage, Edit, Refresh, Unload, custom skin actions (`ContextTitleN` /
  `ContextActionN`, up to 25; a submenu when more than 3).
- **Mac:** the skin's name, its custom actions (same rules; `!SkinCustomMenu` shows only them), Variants, Position,
  Transparency, On Hover, Draggable, Click Through, Keep on Screen, Snap to Edges, Save Position, "Compatibility Notes
  (n)" when there are any, Manage Skin…, Edit Skin… (the Skin Studio), "Edit in <app>" when a code editor app is chosen
  in Settings ▸ Editor, Refresh Skin, Open Skin Folder, Unload Skin.
  FadeDuration and Load Order are set in the Manage window; StartHidden and AutoSelectScreen only through `Default…`
  options and bangs.
- **Why:** Mac menu conventions.
- **Skin impact:** none.
- **Status:** emulated

#### Main menu (the tray menu)
- **Windows:** the notification-area icon's menu; `!TrayMenu` opens it.
- **Mac:** the menu bar icon's menu (Manage Skins…, Skins, loaded skins, Refresh All, Install Skin…, Open Skins
  Folder, Open Log, Launch at Login, About, Quit); `!TrayMenu` pops it up at the pointer. macOS may hide menu bar icons
  (System Settings → Menu Bar): opening Deskset again from Finder, Spotlight or Launchpad shows the Manage window, and
  so does the first launch. A second copy of Deskset hands the files it was opened with to the running one and quits.
- **Why:** macOS lets users hide menu bar items.
- **Skin impact:** none.
- **Status:** emulated

### 7.4 Config and app bangs

#### When `!Refresh`, `!ActivateConfig`, `!DeactivateConfig` and `!ToggleConfig` happen
- **Windows:** the manual does not say when during an action a skin is loaded, unloaded or refreshed.
- **Mac:** on the next turn of the app's run loop, after the action that asked for them has finished (a skin that
  refreshes itself in OnRefreshAction, or two skins refreshing each other, never recurse). Bangs of the same action
  addressed to a config that is about to load wait for it: `[!ActivateConfig X][!Move 10 10 X]` moves the new X. A
  skin cannot reload or unload itself from its OnCloseAction.
- **Why:** judgment call for robustness.
- **Skin impact:** none observed.
- **Status:** emulated

#### `!ActivateConfig` for a config that already runs that file
- **Windows:** "Activates a skin"; without File, "the next .ini file variant in the config folder is activated". The
  manual does not say what happens when the config already runs that file; forum threads about an "already active"
  log warning suggest that the skin is left as it is.
- **Mac:** nothing happens apart from a warning in the log. File names are compared ignoring case; a file the config
  folder does not have falls back to the last used one, and `!ActivateConfig Config` for a config with a single .ini
  file names that file, so both leave the running skin alone too. Another variant still replaces the running one;
  `!Refresh`, `!ToggleConfig`, the Manage window and the menus are not affected.
- **Why:** judgment call. Reloading would let a skin that activates its own config reload itself endlessly
  (Monstercat Visualizer's update notice does that on every load while a newer version exists).
- **Skin impact:** none expected; a skin that wants to reload itself uses `!Refresh`.
- **Status:** emulated (judgment call)

#### `!RefreshApp` and Refresh All
- **Windows:** refreshes Rainmeter and all skins.
- **Mac:** re-reads the Skins folder, decodes images and reads every `@Resources/Fonts` folder again, and refreshes every
  skin; the app itself is not restarted.
- **Why:** —
- **Skin impact:** none.
- **Status:** emulated

#### Layouts (`!LoadLayout`)
- **Windows:** layouts save and restore sets of loaded skins with their settings.
- **Mac:** layouts from packages are installed into `~/Library/Application Support/Deskset/Layouts` but cannot be applied
  yet; `!LoadLayout` adds a compatibility note, and a package that asks to load a layout says so after installing.
- **Why:** not implemented yet.
- **Skin impact:** suites that set themselves up through a layout (Enigma, FluentDash11, Nelamint, Simple Clean,
  PogPack) are loaded skin by skin from the Manage window.
- **Status:** not supported

#### Other host bangs
- **Windows:** `!SetClip`, `!SetWallpaper`, `!Play` / `!PlayLoop` / `!PlayStop`, `!Manage`, `!About`, `!EditSkin`,
  `!Quit`, `!ResetStats`, `!SetAnchor`.
- **Mac:** `!SetClip` sets the pasteboard; `!SetWallpaper` sets the picture of every display (Tile is shown unscaled like
  Center — macOS cannot tile); `!Play` plays one sound at a time; `!Manage` opens the Manage window on the named config;
  `!About Log` opens the log; `!EditSkin` opens the file in the text editor; `!Quit` quits after the current action.
  `!ResetStats` and `!SetAnchor` do nothing and add a compatibility note.
- **Why:** network statistics are not kept across restarts; stored anchors are not implemented yet.
- **Skin impact:** none for the supported ones.
- **Status:** emulated / not supported (`!ResetStats`, `!SetAnchor`)

#### Running programs and opening files (`["…"]`)
- **Windows:** `["program.exe" args]` runs a program; a URL or file opens with its default handler.
- **Mac:** URLs open in the default browser; existing files and folders open with their default app; a Mac `.app` given
  files as arguments opens them (how skins open their settings in `#CONFIGEDITOR#`), other arguments are dropped. A
  Windows program or path that does not exist on the Mac does nothing and is logged ("Windows programs are not
  supported").
- **Why:** `.exe` files cannot run on macOS.
- **Skin impact:** launcher skins pointing at Windows programs (Chrome, Notepad, Explorer paths) need their targets
  changed to Mac apps or URLs.
- **Status:** partial

### 7.5 `Deskset --render` (for skin authors and testing)

#### Rendering a skin to a PNG
- **Windows:** no counterpart.
- **Mac:** `Deskset --render Skin.ini --out x.png [--updates N] [--interval ms] [--scale S] [--background R,G,B[,A]]
  [--skins-dir DIR]` loads the skin without a window, runs N updates (default 2, 1 000 ms apart), draws it at scale S
  (default 2) and prints compatibility notes and log lines. Window, config and app bangs are ignored, mouse actions
  never run, and nothing asks for a permission: no audio is captured, since only skins in skin windows capture
  (`DESKSET_AUDIO_DEMO=1` feeds a generated signal), players look closed (`DESKSET_NOWPLAYING_DEMO=1` fakes a playing
  track). FrostedGlass blur is not visible in the image, and WebParser's `file://` limit to the Skins and settings
  folders ([§11.1](#111-webparser)) applies in the app only. `Deskset --help` (or `-h`) lists every command-line mode;
  an unknown `--` option prints that list and exits with status 2 instead of starting the menu bar app.
- **Why:** repeatable screenshots without prompts or a visible screen.
- **Skin impact:** none (developer tool).
- **Status:** Mac-only

---

## 8. Lua scripting

In short: `Measure=Script`, inline Lua (`[&Script:Function()]`) and the whole SKIN / SELF / Measure / Meter API
work with the reference Lua 5.1.5 (its sources unmodified; a few library functions are removed or replaced at run
time, see below), so scripts behave as on Windows. The differences are safety restrictions, Mac
paths and a few functions that have no Mac meaning. Details: [`compat/lua.md`](compat/lua.md).

#### Lua version and one state per Script measure
- **Windows:** Lua 5.1; each Script measure has its own instance; globals are not shared.
- **Mac:** Lua 5.1.5 built from its unmodified sources (the removed and restricted functions below are replaced at run
  time; the pattern functions are a modified copy of Lua's own code with a recursion limit); one `lua_State` per
  Script measure, created on load, closed on refresh / unload.
- **Why:** same language version.
- **Skin impact:** none.
- **Status:** identical

#### Available libraries and removed functions
- **Windows:** the standard libraries without `require`, `os.exit`, `os.setlocale`, `io.popen`, `collectgarbage`
  and external compiled libraries; `debug`, `setfenv`, `getfenv`, `coroutine` are available.
- **Mac:** the same removals, plus `module` / the `package` library, `debug.sethook`, `newproxy`,
  `debug.getmetatable`, `debug.setmetatable`, `debug.getregistry`; `getmetatable(file)` returns `false`.
- **Why:** these could attach code to garbage collection or remove the time limit, which would let a script freeze
  the app (judgment call).
- **Skin impact:** rare advanced scripts get "attempt to call a nil value" (logged).
- **Status:** partial

#### Functions restricted for memory safety
- **Windows:** stock Lua 5.1 trusts the script completely (`debug.setfenv`, `debug.setlocal`, precompiled bytecode
  in `loadstring`, unbounded pattern recursion).
- **Mac:** `debug.getfenv` / `setfenv` only for Lua functions and threads; `debug.setlocal` does not touch C
  functions or hidden loop variables; `loadstring` / `load` / `dofile` / `loadfile` / ScriptFile accept text only
  ("binary (precompiled) chunks are not supported"); string patterns are limited to 200 nested levels ("pattern too
  complex") and obey the time budget.
- **Why:** a downloaded skin must never crash the app or run native code in it.
- **Skin impact:** none for ordinary scripts; scripts shipped as precompiled bytecode do not run.
- **Status:** partial

#### ScriptFile
- **Windows:** a relative or full path; variables allowed.
- **Mac:** the same; `\` separators and case differences are handled; files over 16 MB or not regular files are not
  read; a missing file gives a compatibility note and the values 0 / "".
- **Why:** skins are written on case-insensitive Windows with `\` paths.
- **Skin impact:** none.
- **Status:** identical

#### Script file encoding
- **Windows:** a `.lua` file must be UTF-16 for Unicode; "NEVER encode a .lua script file in UTF-8".
- **Mac:** decoded like `.ini` files (UTF-8 with or without BOM, UTF-16, UTF-32, else ANSI) and passed to Lua as
  UTF-8; a first line starting with `#` is ignored.
- **Why:** Lua sees text as UTF-8 either way; accepting UTF-8 is a leniency.
- **Skin impact:** UTF-8 scripts that show garbled text on Windows show the intended text on the Mac.
- **Status:** emulated

#### Text exchanged with the skin
- **Windows:** strings are UTF-8 on the Lua side.
- **Mac:** the same; a Lua string that is not valid UTF-8 (e.g. read from an ANSI file) is shown as Windows-1252
  instead of replacement characters (judgment call).
- **Why:** ANSI data files are common.
- **Skin impact:** accented Latin characters from ANSI files display correctly.
- **Status:** identical

#### Main chunk and `Initialize()`
- **Windows:** Initialize runs once when the skin is activated or refreshed, even if the measure is disabled; the
  global scope runs during initialization; a ScriptFile changed by `!SetOption` gets its Initialize called.
- **Mac:** the main chunk runs when the skin loads; Initialize runs at the Script measure's turn in the first update
  (even when disabled, paused or `UpdateDivider` is negative), or earlier if a `!CommandMeasure` reaches the script
  first. Bangs issued while loading run right after Initialize.
- **Why:** the manual does not say where in the first update Initialize runs (judgment call).
- **Skin impact:** none for skins that work on Windows.
- **Status:** identical

#### `Update()` and the measure values
- **Windows:** return nothing / a number / a string / both; the measure honours Disabled, UpdateDivider and measure
  bangs; the value is reset when an error occurs; NumOfDecimals etc. apply to bound meters.
- **Mac:** the same. A returned number has no separate string (meters format it; `[Script]` shows it with up to 5
  decimals, not Lua's `%.14g`); `true` / `false` count as 1 / 0; tables, functions and nil are ignored; a runtime
  error resets the values to 0 and "".
- **Why:** manual plus the inline-Lua rule for booleans.
- **Skin impact:** none expected.
- **Status:** identical

#### MinValue / MaxValue of a Script measure
- **Windows:** measures that cannot know their range use the smallest and largest values seen.
- **Mac:** Script measures are treated that way unless MinValue / MaxValue are set (judgment call).
- **Why:** a script cannot declare its range.
- **Skin impact:** a Bar bound to a script without MaxValue fills relative to the largest value seen.
- **Status:** emulated

#### Deprecated API (`PROPERTIES`, `GetStringValue()`, `GetValue()`, `tolua.cast`, `SetText`)
- **Windows:** deprecated but still supported.
- **Mac:** all work (`PROPERTIES` filled from the measure's options, the global functions supply values when
  `Update()` returns nothing, `tolua.cast(x)` returns `x`, `Meter:SetText(t)` = `!SetOption Meter Text t`).
- **Why:** keeps old scripts working (judgment call on the exact old behaviour).
- **Skin impact:** none expected.
- **Status:** emulated

#### `SKIN:Bang()`
- **Windows:** the bang runs "when control is returned from the script"; `!Delay` is not supported in Lua.
- **Mac:** bangs are queued and run in order after the outermost Lua call returns; each parameter stays whole;
  numbers use Lua's format, booleans become 1 / 0; a single string is run as an action (a bare URL or file as
  `["…"]`); a separate `!Delay` has no effect, inside an action string it delays the rest of that string; at most
  10 000 bangs / 32 MB per call.
- **Why:** the manual's timing rule; the rest keeps real scripts working.
- **Skin impact:** reading a value right after setting it with a bang sees the old value, as on Windows.
- **Status:** identical

#### `SKIN:GetVariable()`, `SKIN:MakePathAbsolute()` and paths
- **Windows:** paths are Windows paths (`C:\…\Skin\`), and scripts split them with patterns such as
  `path:match('([^\\]-)%.([^%.]+)$')`.
- **Mac:** paths handed to scripts (MakePathAbsolute results, `@`, `CURRENTPATH`, `ROOTCONFIGPATH`, `SKINSPATH`,
  `SETTINGSPATH`, `PROGRAMPATH`, `ADDONSPATH`, `PLUGINSPATH`, and the same via `SKIN:ReplaceVariables`) use `\`
  separators (`\Users\me\Library\…\Skin\`); the nesting form `[#@]` and option values read with `GetOption` keep
  `/`. Every path a script gives back accepts `\` or `/`.
- **Why:** path-splitting patterns written for Windows then work unchanged (judgment call).
- **Skin impact:** paths a script displays use backslashes, as on Windows. Scripts written for Deskset should not
  assume `/`.
- **Status:** emulated

#### `SKIN:GetX / GetY / GetW / GetH`, `MoveWindow`, `FadeWindow`
- **Windows:** the skin window's position and size; MoveWindow moves it; FadeWindow fades at FadeDuration speed.
- **Mac:** positions in points from the top-left of the primary screen (as `!Move`); MoveWindow runs `!Move`;
  FadeWindow sets the window to `from` and animates it to `to` (0…255) over FadeDuration, in order with the script's
  bangs. The faded value is **not** saved: it lasts until the skin is refreshed or its AlphaValue is set again
  (`!SetTransparency`, the Transparency menu, the Manage window); OnHover and `!Hide` / `!Show` work on top of it.
- **Why:** macOS points and flipped y axis; the manual does not say whether the faded value persists, and keeping it
  transient never changes the user's saved setting.
- **Skin impact:** after a refresh the skin starts from its saved AlphaValue again.
- **Status:** emulated

#### `SKIN:ReplaceVariables()` and `SKIN:ParseFormula()`
- **Windows:** ReplaceVariables also replaces section variables; ParseFormula needs a parenthesized formula, returns
  nil otherwise.
- **Mac:** the same; ParseFormula also replaces variables first and accepts measure names; invalid input gives nil.
- **Why:** leniency.
- **Skin impact:** none.
- **Status:** identical

#### Measure objects (`SKIN:GetMeasure`, `SELF`)
- **Windows:** GetValue, GetStringValue, GetRelativeValue, GetValueRange, GetMinValue, GetMaxValue, GetOption,
  GetNumberOption, GetName, Disable, Enable.
- **Mac:** all of them; GetStringValue is after Substitute; GetOption sees `!SetOption` values; Disable / Enable act
  at once; calling a method with `.` instead of `:` gives a clear error.
- **Why:** manual (judgment on the nil default).
- **Skin impact:** none.
- **Status:** identical

#### Meter objects (`SKIN:GetMeter`)
- **Windows:** GetOption, GetName, GetX(Absolute), GetY(Absolute), GetW, GetH, SetX…SetH, Hide, Show.
- **Mac:** all of them. GetX() / GetY() return the position relative to the meter's container (the skin for
  ordinary meters), GetX(true) the position in the skin; GetW / GetH include Padding and are 0 for hidden meters;
  SetX…SetH take effect at once. Before the end of the first update (main chunk, Initialize, first Update) the first
  Get / Set call lays the meters out provisionally from their options (see
  [Meter geometry before the first update](#meter-geometry-before-the-first-update)).
- **Why:** the manual does not define the non-absolute position of `r` / `R` meters (judgment call).
- **Skin impact:** scripts that expect GetX() to return an `r` offset get the position; a String meter bound to a
  measure has its real width only after the first update (read it again in a later Update()).
- **Status:** emulated

#### `print()`
- **Windows:** writes to the log.
- **Mac:** writes to the skin log at Notice level; at most 100 lines per second per script; lines over 2000
  characters are cut.
- **Why:** a print in a fast Update must not flood the log.
- **Skin impact:** none.
- **Status:** identical

#### `!CommandMeasure` and inline Lua
- **Windows:** `!CommandMeasure` runs Lua code in a script instance; `[&Script:Function(args)]` calls a function
  (DynamicVariables=1 needed in options; bangs always resolve it).
- **Mac:** the same; commands work on disabled and paused Script measures. In an option without DynamicVariables,
  `[&Script:…]` is resolved once, at the first update, like every section variable. Inline Lua: nil gives "" (logged); a
  table / function result, a missing function or an error leaves the text unresolved (logged); more argument forms
  are accepted (apostrophes inside strings, Windows paths with backslashes, Lua expressions).
- **Why:** manual; leniencies are judgment calls.
- **Skin impact:** none expected.
- **Status:** identical

#### `io` paths and text mode
- **Windows:** Windows paths, relative to the working folder; text mode turns "\r\n" into "\n".
- **Mac:** `\` or `/`; relative paths are relative to the skin folder; existing files are found case-insensitively;
  reading in text mode converts "\r\n" to "\n"; standard input reads nothing.
- **Why:** macOS has no text mode; the app's working folder is `/`.
- **Skin impact:** CRLF data files and Windows paths work. Reading Desktop, Documents or Downloads can show a macOS
  privacy prompt; if refused, `io.open` returns nil and an error.
- **Status:** emulated

#### `dofile` / `loadfile`
- **Windows:** "You must specify a full path".
- **Mac:** files are decoded like script files; relative paths are relative to the skin folder; without a file name
  they raise an error / return nil instead of reading standard input.
- **Why:** consistency with ScriptFile.
- **Skin impact:** none.
- **Status:** identical

#### `os.execute`
- **Windows:** runs a command through cmd.exe; skins mostly use `os.execute('start "" "https://…"')`.
- **Mac:** no shell command is run. `start …`, `cmd /c start …`, `open target` and a bare URL or existing file open
  the target (returns 0). Anything else returns 1 and is logged once.
- **Why:** Windows commands mean nothing to `/bin/sh`, and a blocking command would freeze the skin.
- **Skin impact:** commands that only open things work; others silently do nothing. Use RunCommand for real
  command lines.
- **Status:** partial

#### `os.getenv`
- **Windows:** Windows environment variables.
- **Mac:** real variables first; then USERNAME → USER, USERPROFILE / HOMEPATH → HOME, HOMEDRIVE → "", APPDATA /
  LOCALAPPDATA → `~/Library/Application Support`, TEMP / TMP → the temporary folder, PROGRAMFILES → `/Applications`;
  other names are nil.
- **Why:** scripts build paths from them.
- **Skin impact:** those paths point at the Mac equivalents.
- **Status:** emulated

#### `os.date`, `os.clock` and other `os` functions
- **Windows:** Microsoft C library (`%#d` removes leading zeros; `clock()` is wall-clock time).
- **Mac:** `%#x` flags are emulated; `os.clock` returns wall-clock seconds (the Mac C library would return CPU time);
  `math.random` sequences differ.
- **Why:** scripts time animations with `os.clock`.
- **Skin impact:** none expected.
- **Status:** emulated

#### Error messages
- **Windows:** logged in the About window.
- **Mac:** logged as `[Measure] Script: Root/Sub/File.lua:12: message`; each distinct message once per script (at
  most 100), cut at 2000 characters.
- **Why:** log volume.
- **Skin impact:** repeated errors appear once.
- **Status:** emulated

#### Runaway scripts and memory
- **Windows:** not documented (an endless loop freezes Rainmeter).
- **Mac:** each outermost call may run 200 million instructions and 2 seconds; a stopped call raises "script stopped
  after … (endless loop?)" that `pcall` cannot catch; after 3 stops in a row the script is stopped until refresh
  (compatibility note). 64 MB per script, 512 MB for all scripts; 32 nested calls.
- **Why:** a skin must never hang or crash the app.
- **Skin impact:** legitimate scripts are far below the limits.
- **Status:** emulated

#### Threading
- **Windows:** scripts run on the skin's thread.
- **Mac:** scripts run synchronously on the thread that updates the skin (the main thread).
- **Why:** skins are not thread-safe.
- **Skin impact:** slow `io` on network volumes blocks the skin, as on Windows.
- **Status:** identical

---

## 9. Bundled plugins (core)

Rainmeter's plugins that need no Apple UI or media framework: ActionTimer, CoreTemp, SpeedFan, AdvancedCPU,
UsageMonitor, PerfMon, Ping, RunCommand, Quote, FolderInfo, FileView, RecycleManager, ResMon, WindowMessage and
VirtualDesktops, and the third-party Mouse plugin (§9.8) with Slider, its version 2 (§9.9). Details:
[`compat/plugins.md`](compat/plugins.md).

### 9.1 General

#### Plugin names and aliases
- **Windows:** `Measure=Plugin` + `Plugin=Name`, `Name.dll` or `Plugins\Name.dll`; RecycleManager also as a measure.
- **Mac:** every form is accepted, case-insensitively, including `PingPlugin` / `Ping`, `QuotePlugin` / `Quote`,
  `PerfMon` / `PerfMonPlugin`, `SpeedFanPlugin` / `SpeedFan`, `WindowMessagePlugin` / `WindowMessage`.
- **Why:** legacy skins use every spelling.
- **Skin impact:** none.
- **Status:** identical

#### Range (MinValue / MaxValue) of plugin measures
- **Windows:** measures that cannot know their maximum use the smallest and largest values seen; CoreTemp and
  SpeedFan say MinValue / MaxValue "must be added" for percentages.
- **Mac:** every core plugin measure whose number changes (CoreTemp, SpeedFan, AdvancedCPU, UsageMonitor, PerfMon,
  ResMon, Ping, RunCommand, FolderInfo, FileView, RecycleManager) tracks its observed range unless MinValue / MaxValue
  are set; ActionTimer, Quote, WindowMessage, VirtualDesktops, Mouse and Slider keep the fixed 0…1 range.
- **Why:** the manual describes this for plugin measures in general.
- **Skin impact:** bars without MaxValue scale to the largest value seen, as on Windows.
- **Status:** identical

#### Background work and unloading
- **Windows:** plugins work in their own threads; RunCommand kills hidden programs on refresh / unload.
- **Mac:** pings, commands, folder scans, the Trash and per-process sampling run in the background and hand their
  results to the skin (the value is set before the plugin's FinishAction runs). On refresh / unload timers stop,
  pings are cancelled and hidden RunCommand programs are killed.
- **Why:** nothing may block the skins.
- **Skin impact:** a background value appears at the next update or when FinishAction runs.
- **Status:** emulated

#### Windows paths in plugin options
- **Windows:** Path / PathName / Folder / StartInFolder / OutputFile / IconPath take Windows paths.
- **Mac:** `\` becomes `/`; `%USERPROFILE%`, `%HOMEDRIVE%%HOMEPATH%` → home folder; `%APPDATA%` / `%LOCALAPPDATA%` →
  `~/Library/Application Support`; `%TEMP%` → the temporary folder; `%PUBLIC%` → `/Users/Shared`;
  `%PROGRAMFILES%` → `/Applications`; `%PROGRAMDATA%` → `/Library/Application Support`; `%WINDIR%` → `/System`;
  `C:\Users\<anyone>\X` → `~/X` (Videos → Movies, My Pictures → Pictures, …); other drive-letter paths → the same path
  under `/`; relative paths from the skin folder.
- **Why:** the Mac has no drives and a different home layout (judgment call).
- **Skin impact:** galleries of `%USERPROFILE%\Pictures`, notes in Documents etc. work; paths to other drives usually
  do not exist.
- **Status:** emulated

#### Privacy prompts
- **Windows:** no prompts.
- **Mac:** reading Desktop, Documents, Downloads, removable or network volumes (Quote, FolderInfo, FileView) asks once;
  controlling Finder (RecycleManager emptying, FileView Properties) asks once for Automation; RecycleManager `Size`
  needs Full Disk Access (no prompt; without it a compatibility note says so). Refused → empty values / nothing
  happens, logged once.
- **Why:** macOS privacy protection.
- **Skin impact:** a one-time system dialog ([§4](#4-macos-permissions)).
- **Status:** emulated

### 9.2 ActionTimer

#### ActionList, Wait, Repeat, Execute, Stop
- **Windows:** `ActionListN=Action | Wait ms | Repeat Action, ms, count`; Execute starts a list, Stop ends it; a running
  list ignores Execute.
- **Mac:** identical semantics; lists run in parallel; a list counts as finished when its last action starts, so that
  action can `Execute` the same list again (the usual way to loop an animation).
- **Why:** —
- **Skin impact:** none.
- **Status:** identical

#### Timing
- **Windows:** "as fast as it possibly can", paced by the Waits.
- **Mac:** steps run on the main run loop (also while a menu is open); each Wait is counted from the previous step's
  scheduled time (no drift); a step more than 100 ms late restarts the schedule instead of firing missed steps in a
  burst; at most 64 actions per run-loop turn; counts capped at 10 million, waits at 24 h.
- **Why:** drawing must happen on the main thread; drift-free scheduling.
- **Skin impact:** animations are at least as smooth.
- **Status:** emulated

#### Variables in actions and other details
- **Windows:** actions work like any action option; `!UpdateMeasure` is needed to pick up changed `#Variables#`.
- **Mac:** the same; `[SectionVariables]` are resolved when each action runs; commands work while the measure is
  disabled or paused; an undefined list is logged; the value is 0.
- **Why:** judgment where the manual is silent.
- **Skin impact:** none.
- **Status:** identical

### 9.3 Hardware sensors: CoreTemp and SpeedFan

#### CoreTemp
- **Windows:** reads the Core Temp application, which must be running.
- **Mac:** values come from the Mac: `Load` = per-core CPU usage (0-based index); `CpuName` = the processor name
  ("Apple M4 Pro"); `CpuSpeed` / `CoreSpeed` = MHz when macOS reports one (Intel), else 0; `Temperature`,
  `MaxTemperature` (default), `TjMax`, `Vid`, `Tdp`, `Power` = 0 until sensor support ships; bus values 0 on Apple
  silicon. Always Celsius.
- **Why:** macOS has no public temperature / voltage API (SMC keys differ per chip and need privileges).
- **Skin impact:** load bars and the CPU name work; temperatures read 0 (logged once).
- **Status:** partial

#### SpeedFan
- **Windows:** reads the SpeedFan application (temperatures, fans, voltages).
- **Mac:** the same options, but values are 0 until hardware sensor support exists (logged once).
- **Why:** no SpeedFan and no public sensor API.
- **Skin impact:** fan / temperature displays read 0.
- **Status:** partial

### 9.4 Process and performance counters

#### AdvancedCPU (deprecated)
- **Windows:** process CPU time scaled by the number of cores; `TopProcess`, `CPUInclude` / `CPUExclude`.
- **Mac:** CPU time used since the previous update, in 100 ns units (as Windows' counters), so skins' own
  percentage maths works; `Idle` = idle time of all cores; processes of other users (WindowServer, kernel_task,
  daemons) are reported together as one process named `System`; names are Mac executable names; `.exe` is ignored in
  lists; `Rainmeter` means Deskset; sampled once a second in the background.
- **Why:** macOS hides other users' process details; no blocking work on the main thread.
- **Skin impact:** "System" can appear as a top process (exclude it with `CPUExclude=Idle;System`); lists naming
  Windows programs match nothing; values appear after the first two samples.
- **Status:** emulated

#### UsageMonitor
- **Windows:** any Performance Monitor Category / Counter / Instance, or an Alias (CPU, RAM, IO, GPU, VRAM…).
- **Mac:** the common counters are emulated: Process (`% Processor Time`, `Working Set - Private`, `Private Bytes`,
  `Virtual Bytes`, `Thread Count`, `ID Process`, IO bytes/sec…), Processor (per-core times), Memory (`Available
  Bytes`, `Committed Bytes`, `Commit Limit`…), Paging File, Network Interface (bytes/sec), LogicalDisk / PhysicalDisk
  (free space, bytes/sec), System (processes, threads, uptime, load). Index, Name, Blacklist / Whitelist, Rollup,
  Percent, RawValue and PIDToName follow the manual (names also match case-insensitively and without `.exe`).
  GPU counters need sensor support; anything else reads 0 and is listed as a compatibility note.
- **Why:** macOS has no Performance Monitor; these are the Darwin equivalents.
- **Skin impact:** top-process lists, per-core loads, network and memory counters work; GPU and exotic counters read 0.
- **Status:** partial

#### PerfMon (deprecated)
- **Windows:** `PerfMonObject` / `Counter` / `Instance`, with or without `PerfMonDifference`.
- **Mac:** the same counters as UsageMonitor, reported as raw values (with PerfMonDifference=1 the change since the
  previous update; Processor `% Processor Time` is an inverse timer, as skins expect). An unknown network adapter
  name means all interfaces.
- **Why:** judgment from the manual's description.
- **Skin impact:** per-core graphs (PogPack) work; unknown counters (e.g. `Current Bandwidth`) read 0.
- **Status:** partial

#### ResMon
- **Windows:** GDI, USER, Handle and Window counts, optionally for one process.
- **Mac:** `Handle` = open file descriptors (of the named processes, else the whole system); GDI, USER and Window read 0.
- **Why:** macOS has no GDI / USER objects.
- **Skin impact:** GDI / USER displays read 0.
- **Status:** partial

### 9.5 Ping and RunCommand

#### Ping
- **Windows:** round-trip time to `DestAddress`; `UpdateRate`, `Timeout`, `TimeoutValue`, `FinishAction`.
- **Mac:** an unprivileged ICMP echo on a background thread (IPv4 preferred); pings on the first update and every
  UpdateRate updates; whole milliseconds; 0 until the first reply. Unresolvable names and send errors count as a
  timeout; an empty DestAddress pings nothing.
- **Why:** macOS allows ICMP echo without root.
- **Skin impact:** none; offline skins show TimeoutValue.
- **Status:** identical

#### RunCommand: how commands run
- **Windows:** `Program` (default cmd.exe) + `Parameter`, run hidden, standard output captured.
- **Mac:** the command line runs through `/bin/sh -c` in the skin folder with a PATH that includes Homebrew and a
  UTF-8 locale. An empty Program or `cmd.exe` means "the Parameter is the command line"; a Mac program (`python3`,
  `osascript`) gets the Parameter appended. Quotes, escapes and redirections reach the shell unchanged.
- **Why:** POSIX commands are the Mac's command-line programs.
- **Skin impact:** portable commands (`curl …`, `echo`, `whoami`, `hostname`) work unchanged.
- **Status:** emulated

#### RunCommand: Windows-only commands
- **Windows:** any Windows program or cmd.exe command.
- **Mac:** never passed to the shell: PowerShell, wscript / cscript, mshta, rundll32, cmd built-ins without a Mac
  counterpart (`dir`, `copy`, `del`, `tasklist`, `wmic`, `reg`, `netsh`…), programs ending in `.exe`, `.bat`, `.cmd`,
  `.ps1`, `.vbs`…, command lines with cmd.exe variables, drive-letter or UNC paths. They fail with error 103 before
  anything starts. Shared names (`find`, `sort`, `date`, `ping`, `for`…) run through the shell unless they use Windows
  syntax (`/switches`). Translated: `start` / `explorer target` → `open target`; Windows `ping -n N` → `ping -c N`;
  `type file` → `cat file`; cmd's `&` separator → `;`; `2>nul` → `/dev/null`.
- **Why:** running a Windows command line in another shell could do something the author did not mean.
- **Skin impact:** PowerShell / WMIC-based info skins show nothing (error 103); portable and Mac command lines work.
- **Status:** partial

#### RunCommand: FinishAction after a failed start
- **Windows:** FinishAction runs when the program has finished; 103 is "Cannot start program".
- **Mac:** after error 103 the FinishAction still runs, so skins that wait for it move on (except when the same
  measure failed less than a second earlier, to avoid loops). Judgment call.
- **Why:** graceful degradation for Windows-only commands.
- **Skin impact:** an empty result instead of waiting forever.
- **Status:** emulated

#### RunCommand: values, error codes, State, Close, Kill, Timeout, output
- **Windows:** -1 before the first run, 0 running, 1 success, 100–106 errors; `State` Hide / Show / Minimized /
  Maximized; Close / Kill; OutputType UTF16 / UTF8 / ANSI.
- **Mac:** the same codes; the exit status does not matter; standard error is discarded (`2>&1` keeps it); output
  capped at 16 MB. Command-line programs have no window, so `State` only decides whether a program is killed on
  refresh (Hide, the default). Close = SIGTERM, Kill = SIGKILL; a program ignoring Close for a second is no longer
  waited for. Output is read as UTF-8 whatever OutputType says; OutputFile is written in the OutputType encoding.
- **Why:** no console windows on the Mac; Mac programs write UTF-8.
- **Skin impact:** none.
- **Status:** emulated

### 9.6 Files and folders

#### QuotePlugin
- **Windows:** a random part of a file (split by `Separator`) or a random file of a folder (`Subfolders`,
  `FileFilter`).
- **Mac:** the same; a new random item at every update, never the same twice in a row; hidden and Finder files are
  skipped; files decoded like skin files; the folder is read in the background (again when older than a minute); at
  most 100 000 items.
- **Why:** no file I/O on the main thread.
- **Skin impact:** the value is empty for a moment after loading.
- **Status:** identical

#### FolderInfo
- **Windows:** FileCount / FolderCount / FolderSize with RegExpFilter, subfolders, hidden and system files.
- **Mac:** the same options; hidden = dot files and the hidden flag; system = Finder bookkeeping files
  (`.DS_Store`, `._*`…); packages (`.app`) are folders; links are not followed; scans run in the background (a slow
  scan is repeated less often); at most 2 million entries.
- **Why:** Mac file attributes; no I/O on the main thread.
- **Skin impact:** counts can differ slightly from Explorer's; large folders never freeze the skin.
- **Status:** emulated

#### FileView
- **Windows:** a parent measure lists a folder (default "This PC"); children read items by Index; commands
  FollowPath, Open, PreviousFolder, ContextMenu, Properties; Type=Icon writes `.ico` files.
- **Mac:** the same model; the default path is `/Volumes/` (the mounted volumes); Finder-like order (`..`, folders,
  files; natural name sort); FileDate in the user's locale; paths use `/`. `Type=Icon` writes Finder's icon at IconSize
  in the background, as a real `.ico` file for `.ico` paths up to 256 px and as PNG data otherwise (the Image meter
  reads both), creating missing folders on IconPath. ContextMenu reveals the item in Finder (another app's Finder
  context menu cannot be shown); Properties opens Finder's Get Info window (Automation permission).
- **Why:** macOS paths and APIs.
- **Skin impact:** right-click menus become "show in Finder"; skins that parse `\` out of paths need `/`.
- **Status:** partial

#### RecycleManager
- **Windows:** `Count` / `Size` of the Recycle Bin; OpenBin, EmptyBin, EmptyBinSilent.
- **Mac:** the Trash (`~/.Trash` plus the Trash of other internal volumes). Count works without permission; Size
  needs Full Disk Access (else 0, with a compatibility note and a log line saying where to grant it; the note goes
  away once the size can be read). OpenBin opens the Trash in Finder;
  EmptyBin asks through Finder's own confirmation, EmptyBinSilent empties without it (Automation permission for
  Finder). The old `Drives=` option is ignored.
- **Why:** macOS protects the Trash's contents; the Trash belongs to Finder.
- **Skin impact:** item counts work; size skins show 0 until Full Disk Access is granted.
- **Status:** partial

### 9.7 No macOS counterpart

#### WindowMessage
- **Windows:** sends window messages to another program's window and returns the result or its title.
- **Mac:** value 0, string "", commands ignored (logged once).
- **Why:** macOS has no window messages; other apps' window titles need Screen Recording permission.
- **Skin impact:** Winamp-style controls do nothing.
- **Status:** not supported

#### VirtualDesktops
- **Windows:** a plugin for the Dexpot / VirtuaWin desktop managers.
- **Mac:** a single desktop is reported (count 1, current 1, name "Desktop 1"); commands are ignored.
- **Why:** macOS Spaces have no public API.
- **Skin impact:** desktop pagers show one desktop.
- **Status:** not supported

### 9.8 Mouse (third-party: drag sliders)

#### Actions, `$MouseX$` / `$MouseY$`, RelativeToSkin
- **Windows:** the plugin runs every mouse action option "not limited to a meter", plus `MouseMoveAction` and
  `LeftMouseDragAction` … `X2MouseDragAction` (after the move action); `$MouseX$` / `$MouseY$` are relative to the skin,
  or with `RelativeToSkin=0` to "the monitor's top-left corner".
- **Mac:** the same actions: Down / Up / DoubleClick of all five buttons, the scroll actions, MouseMoveAction (also as
  `MoveAction`), the drag actions, and MouseOverAction / MouseLeaveAction when the pointer comes over / leaves the skin.
  A double click runs the DoubleClick action, then the Down action. RelativeToSkin=0 gives screen coordinates from the
  primary screen's top-left corner; `$MouseX:%$` / `$MouseY:%$` are not replaced. The value is 0.
- **Why:** judgment for the hover actions ("all action options") and for "the monitor".
- **Skin impact:** none expected.
- **Status:** identical

#### Where the input comes from, and the order
- **Windows:** version 3.2 watches the mouse input of Rainmeter's own windows (earlier versions hooked the mouse
  globally); forum posts report that without RequireDragging a drag stops reaching it once the pointer leaves the skin.
  The order against the skin's own mouse actions is not documented.
- **Mac:** the skin window's input. A press that started on the skin is followed until its button goes up, also outside
  the skin; a press that started elsewhere is never a drag; ⌘-presses and Control-clicks are not reported; a lost
  release is reported with the next move. The Mouse measures get each event before the meters.
- **Why:** macOS hands a press's drags and release to the window where it started; a lost release would leave a skin
  half-way through a drag.
- **Skin impact:** sliders keep following the pointer past the skin's border. When a meter's LeftMouseDownAction enables
  or starts the measure, the measure's own LeftMouseDownAction does not run for that press.
- **Status:** emulated

#### RequireDragging, Start and Stop; disabled and paused
- **Windows:** with `RequireDragging=1` the plugin accepts `!CommandMeasure … "Start"` / `"Stop"` "to set mouse
  capturing to happen outside borders"; without it a paused or disabled measure needs DynamicVariables=1 and an update.
- **Mac:** with RequireDragging=1 the actions run only between Start and Stop (the commands also work while the measure
  is disabled or paused); without it Start / Stop are ignored with a warning. Disabling or pausing stops the actions at
  once; enabling works without an update (the documented update works too).
- **Why:** judgment — published skins start the measure from the meter being dragged and stop it on release, and skins
  with one measure per slider rely on only the started one reacting.
- **Skin impact:** none expected.
- **Status:** emulated

#### UpdateRate and options of older versions
- **Windows:** version 3.0 documented `UpdateRate` (default 20) as "the interval (in milliseconds) for executing the
  plugin's move and drag actions", and `NeedsFocus`; later versions dropped both. Versions 2.x were a plugin named
  Slider.
- **Mac:** move and drag actions run at most once per UpdateRate milliseconds (0 = every move); the newest waiting
  position runs when the interval ends or before the measure's next other action, so a release comes after the final
  drag position. NeedsFocus is ignored. `Plugin=Slider` is a measure of its own (§9.9).
- **Why:** the documented meaning; it also spares skins whose drag action writes a file on every move.
- **Skin impact:** at most 50 move / drag actions a second by default. A measure with NeedsFocus=1 also acts while its
  skin does not have the focus.
- **Status:** partial

### 9.9 Slider (third-party: the Mouse plugin's version 2)

#### Options and actions
- **Windows:** `MouseButton` (Left, Right or Middle) picks the button; `ClickAction` / `ReleaseAction` run when it is
  pressed / released, `DragAction` when it is pressed and the mouse moves, `HoldAction` when it is held for
  `HoldDelay` milliseconds (default 300), and `MoveAction` when the mouse moves. `$MouseX$` / `$MouseY$` and
  `RelativeToSkin` work as in the Mouse plugin.
- **Mac:** the same. MouseButton is read in any case (any other value is the left button, with a warning);
  MoveAction also runs during a drag, before DragAction; a double click is one more press. Version 3's options and
  undocumented ones (`MoveDelay`) are not read, and there are no commands. The value is 0.
- **Why:** judgment for MoveAction during a drag and for other MouseButton values.
- **Skin impact:** none expected. With MouseButton=Right a right click still opens the skin menu, unless a meter's
  right-button action keeps it closed.
- **Status:** identical

#### Which input it gets
- **Windows:** not documented as such; version 2 watches the mouse on its own thread, and version 3.2 "Uses process
  hook instead of a global one", so version 2 sees the mouse on the whole screen. Published skins expect clicks
  anywhere (Keystrokes' mouse buttons; VisBubble's settings window closes its pop-up menus on them).
- **Mac:** on the skin, the Mouse plugin's input (§9.8): presses of the tracked button, followed until the button goes
  up, also outside the skin, and moves over the skin. Elsewhere on the screen — other apps, the desktop, transparent
  parts of skins, hidden or click-through skins, Deskset's other windows (another skin, the skin editor, the Manage
  window) — the same actions run: Click / Release for the tracked button, Drag and Hold for its presses there,
  MoveAction for every move and drag, with `$MouseX$` / `$MouseY$` outside the skin (screen coordinates with
  RelativeToSkin=0, on any screen). A skin's own window never reports a click twice; input from elsewhere reaches only
  Slider measures, in file order. A Control-click elsewhere is a left press.
- **Why:** judgment — the whole-screen watching of the versions before 3.2, which skins written for version 2 rely on.
- **Skin impact:** none expected: Keystrokes shows every click, VisBubble closes its pop-up menus on clicks elsewhere.
- **Status:** emulated

#### Watching the mouse elsewhere on the screen
- **Windows:** a hook or a polling thread; nothing is asked of the user.
- **Mac:** AppKit's event monitors (other apps; Deskset's own windows), mouse events only: no permission (only key
  events would need Accessibility; keys are never watched). They exist only while a loaded skin has an enabled, unpaused
  Slider measure whose actions need them, watch only that (the button's presses and releases, its drags for Drag / Hold
  while a press made elsewhere is held, every move for MoveAction), and go when no such measure remains (disabled,
  unloaded, refreshed without it, quit). Previews, `--render` and the self-tests never watch. Input reaches the skins on
  the main thread right after macOS reports it; move and drag actions keep their 20 ms cooldown. A press in Deskset's
  own windows is followed by reading the pointer every 20 ms until its button goes up (their controls take its drags and
  release).
- **Why:** macOS has no global mouse hook without Accessibility; event monitors need none.
- **Skin impact:** clicks in Deskset's own menus are not seen, and moves over Deskset's windows other than skins may be
  missed. With a MoveAction, the action runs whenever the mouse moves anywhere (at most 50 times a second).
- **Status:** emulated

#### HoldAction, the 20 ms cooldown, disabled and paused
- **Windows:** HoldAction runs when the button "is held for a delay"; version 2.0.0.24 runs "with a 20 ms cooldown".
  Nothing else is documented.
- **Mac:** the hold runs once per press, when the button is still down after HoldDelay, with the pointer's position
  then; a release before that ends it. Move and drag actions run at most every 20 ms, and a waiting position runs
  before a release or a hold. Disabled and paused as for the Mouse plugin: a measure turned on by the pressed meter
  (NXT-OS's scroll bars) drags and releases that press, but its ClickAction does not run for it. A disabled or paused
  measure does not watch the mouse elsewhere: a press made elsewhere meanwhile is not followed once it is on again.
- **Why:** judgment — the documentation says nothing more.
- **Skin impact:** at most 50 move / drag actions a second; the last position is never lost.
- **Status:** emulated

---

## 10. Audio, media, network and UI plugins

These plugins are rebuilt on Core Audio, AppleScript (Music / Spotify), CoreWLAN and AppKit. Details:
[`compat/audio.md`](compat/audio.md) and [`compat/media-ui.md`](compat/media-ui.md). Permissions are summarised in
[§4](#4-macos-permissions).

### 10.1 AudioLevel (visualizers and level meters)

#### The plugin
- **Windows:** monitors the post-mixer signal of a Windows audio endpoint with a WASAPI loopback capture.
- **Mac:** implemented natively (`AudioLevel`, `AudioLevel.dll`, `Plugins\AudioLevel.dll`). One shared capture
  engine serves every skin: a stream is captured once however many skins use it, starts at the first update of the
  first parent measure in a skin window — never when a skin is only checked (the Manage window, for skins that are not
  loaded) or drawn with `--render` — and stops 3 s after the last one is gone; capture also pauses while skin updates
  are paused (sleep, displays asleep, another user's session). Cost on Apple silicon: 0.1–0.3 % of one core for
  typical visualizers.
- **Why:** WASAPI does not exist on macOS.
- **Skin impact:** none for skin authors.
- **Status:** emulated

#### `Port=Output` (system audio), macOS 14.2 and later
- **Windows:** loopback capture of the default (or `ID`) output endpoint.
- **Mac:** a Core Audio process tap: without `ID` a stereo mixdown of everything apps play; with an `ID` naming an
  output device, that device's stream. Recreated when the output device, the device list or the sample rate changes
  (≈ 0.3 s gap). An output device that also has inputs (USB interfaces, headsets) is not added to the capture
  aggregate, so a visualizer never records a microphone or switches Bluetooth headphones to their call profile.
- **Why:** process taps are the public API for system audio capture.
- **Skin impact:** macOS asks once for **System Audio Recording** and shows its purple recording indicator while a
  visualizer runs. If refused, macOS delivers silence (levels 0). When a system-audio stream carries only digital
  silence over two checks 10 s apart while another app is playing sound, the skin gets a compatibility note pointing
  to the permission (it goes away once sound arrives).
- **Status:** emulated

#### `Port=Output` on macOS 13 – 14.1
- **Windows:** as above.
- **Mac:** ScreenCaptureKit audio capture of the whole system mix; needs the **Screen Recording** permission and a
  restart of Deskset after granting it; `ID` cannot select a device.
- **Why:** process taps do not exist before 14.2.
- **Skin impact:** a Screen Recording prompt for a visualizer is surprising; values are 0 until granted.
- **Status:** emulated (not tested on those macOS versions)

#### `Port=Input`
- **Windows:** capture of the default (or `ID`) input endpoint.
- **Mac:** the input device directly, following default-input changes; needs the **Microphone** permission.
- **Why:** —
- **Skin impact:** the orange microphone indicator while capturing; refused → 0, `DeviceStatus` 0 and a compatibility
  note. Deskset tries again every 10 s, so the levels start (and the note goes away) once the microphone is allowed.
- **Status:** identical (different permission UI)

#### `ID`
- **Windows:** a Windows endpoint ID such as `{0.0.0.00000000}.{…}`.
- **Mac:** a Core Audio device UID or, for convenience, a device name (`ID=MacBook Pro Microphone`). An ID that matches
  nothing (every Windows ID) falls back to the default device (logged once).
- **Why:** Windows endpoint IDs mean nothing on a Mac.
- **Skin impact:** skins shipped with a Windows ID use the default device. `Type=DeviceList` shows the IDs to use.
- **Status:** emulated

#### Parent / child measures and judgment calls
- **Windows:** a parent captures; children (`Parent=`) read values; only Type, Channel, FFTIdx and BandIdx can change
  dynamically.
- **Mac:** the same (parent options are read once). Judgment calls: an invalid `Port` means Output; a parent's own
  value is 0 unless it has a `Type`; a child with a missing or wrong parent, an unknown Type or Channel reads 0 / Sum
  with one warning; a parent disabled at load starts no capture until enabled, and a parent disabled later with
  `!DisableMeasure` keeps capturing (and the recording indicator on) until the skin is refreshed or unloaded.
- **Why:** the manual is silent on these.
- **Skin impact:** none for valid skins.
- **Status:** identical

#### `Channel`
- **Windows:** L/FL/0, R/FR/1, C/2, LFE/3, BL/4, BR/5, SL/6, SR/7, Sum/Avg.
- **Mac:** same names. The default system stream is a stereo mixdown, so C, LFE, BL, BR, SL, SR read 0 there; with an
  `ID` naming a multichannel device the number is the position in that device's stream (device order, not Windows'
  speaker order). Mono inputs answer L, R and C with their only channel.
- **Why:** macOS mixes apps to stereo for the global tap.
- **Skin impact:** 5.1 / 7.1 meters stay at 0 unless the skin names a multichannel device.
- **Status:** partial

#### RMS and Peak (`RMSAttack`, `RMSDecay`, `RMSGain`, `PeakAttack`, `PeakDecay`, `PeakGain`)
- **Windows:** the intent is documented (square, average, root; attack / decay interpolation times), not the formula.
- **Mac:** 5 ms slices drive a one-pole follower with the attack time while rising and the decay time while falling;
  × gain, clipped to 0…1. A full-scale sine reads 0.707 (RMS) / 1.0 (Peak). With no audio for 0.1 s values decay
  instead of freezing; when a capture stops they reset to 0.
- **Why:** time-constant followers are the standard meaning of attack / decay times.
- **Skin impact:** needle speeds may differ slightly from Windows.
- **Status:** emulated

#### FFT, Bands and Sensitivity
- **Windows:** FFTSize, FFTOverlap (Hann window), FFTIdx, Bands (log-spaced), FreqMin / FreqMax, Sensitivity (dB range),
  FFTAttack / FFTDecay.
- **Mac:** Hann-windowed vDSP FFT (non-power-of-two sizes are handled; FFTSize ≤ 65536; computed at most ~60 times
  per second). Bands integrate the power spectrum over each log-spaced band, per octave, so pink noise draws a flat
  line and the level does not depend on the number of bands. Values = `1 + (dB + 10) / Sensitivity`, clipped to 0…1
  (a calibration choice tuned on typical music). Attack / decay are applied to the displayed 0…1 values. FFTFreq uses
  the stream's sample rate; BandFreq is the band's geometric centre.
- **Why:** the manual does not define the reference level or how bins are combined.
- **Skin impact:** bar heights may be somewhat taller or shorter than on Windows for the same music; adjust
  `Sensitivity`. Band labels may differ by up to half a band.
- **Status:** emulated

#### `Type=Format`, `DeviceStatus`, `DeviceName`, `DeviceID`, `DeviceList`
- **Windows:** format text, status 0 / 1, name / ID, a list of device IDs.
- **Mac:** Format like `48000 Hz, 32-bit float, 2 channels`; DeviceStatus 1 while capturing (a refused System Audio
  Recording permission cannot be detected, so it stays 1); Mac device names and UIDs, available even before capture;
  DeviceList has one `UID: Name` per line.
- **Why:** these formats are not documented.
- **Skin impact:** different wording; skins that parse the Windows list format will not match.
- **Status:** emulated / partial (DeviceStatus)

### 10.2 Win7Audio (volume, mute, output device)

#### The plugin and its values
- **Windows:** controls the default Windows output endpoint; number = volume 0–100; string = device name.
- **Mac:** the default Core Audio output device (`Win7AudioPlugin`, `.dll`, `Plugins\…`, `Win7Audio`); no permission.
  Number = volume in whole percent, **−1 while muted** (what skins test for), 100 for a device without a volume
  control (HDMI, some USB DACs); string = the Mac device name. Commands update the shown value at once and reach the
  device asynchronously; fast repeated commands (a scroll wheel) build on each other.
- **Why:** −1 for muted is not in the manual but is what skins rely on.
- **Skin impact:** identical for skins written against the real plugin.
- **Status:** emulated

#### Commands
- **Windows:** SetVolume, ChangeVolume, ToggleMute, ToggleNext, TogglePrevious, SetOutputIndex.
- **Mac:** all of them. Results are clipped to 0…100; formulas are accepted. A device without a mute control is muted
  by setting its volume to 0 and restoring it. `Mute` / `Unmute` are accepted too. Device switching sets the macOS
  default output; `SetOutputIndex` is 1-based; an index out of range is ignored (logged). Unknown commands are logged.
- **Why:** the manual gives neither the device order nor the index base (judgment calls).
- **Skin impact:** device order differs from Windows; skins with hard-coded indices point to the Mac's devices.
- **Status:** emulated

### 10.3 AppVolume (third-party, per-app audio)

#### App list, volume, peak and mute
- **Windows (plugin README):** per-app sessions with their own volume, peak and mute.
- **Mac:** the list is Core Audio's audio clients (macOS 14.2+): Dock apps, plus other playing processes with
  `IgnoreSystemSound=0`; names are executable names. **Volume** is always 1.0 (0 while muted) and `SetVolume` is
  refused — macOS has no per-app volume. **Peak** comes from a process tap of that app (System Audio Recording; only
  in skin windows, so a render reads 0).
  **Mute** creates a muted tap that silences the app until unmuted or Deskset quits. Browsers play through helper
  processes, which are listed only with `IgnoreSystemSound=0`.
- **Why:** macOS has per-app taps but no per-app volume.
- **Skin impact:** per-app volume sliders do nothing; before macOS 14.2 the list is empty. Unloading or refreshing
  the skin does not unmute an app it muted (as on Windows); macOS has no mixer to unmute it from, so it plays again
  when a skin unmutes it or Deskset quits.
- **Status:** partial

### 10.4 Music players: NowPlaying, iTunes, WebNowPlaying, MediaKey

#### How the Automation permission is used
- **Windows:** no equivalent.
- **Mac:** before the first Apple Event to a *running* player, Deskset checks the permission and lets macOS show its
  prompt; only an explicit refusal stops polling that player, and it is re-checked every 30 s so granting it later
  works without a restart. Players are never launched by polling.
- **Why:** macOS privacy protection for Apple Events.
- **Skin impact:** a one-time "Deskset wants to control Music / Spotify" prompt.
- **Status:** emulated

#### NowPlaying: `PlayerName`
- **Windows:** AIMP, CAD (foobar2000, MusicBee…), iTunes, Winamp, WMP, Spotify, WLM, or `[MainMeasure]`.
- **Mac:** only Music.app and Spotify can be read. `Spotify` prefers Spotify; every other name prefers Music.app.
  **Whichever is playing** is shown: the preferred player when it plays, otherwise another playing player, otherwise
  the last one shown if paused, and so on. `[MainMeasure]` references work (up to 8 levels). A player name without a
  Mac version (Winamp, foobar2000, AIMP, WMP, MusicBee…) adds a compatibility note saying which player is shown instead.
- **Why:** those are the scriptable players on macOS; a Windows skin hard-codes a player the Mac user may not use.
- **Skin impact:** skins written for any player work with whatever the user plays on the Mac.
- **Status:** emulated

#### NowPlaying: other players (QQ Music, NetEase Cloud Music, browsers, VLC…)
- **Windows:** only the players listed above are supported either.
- **Mac:** not read. They have no scripting interface, and since macOS 15.4 the system-wide Now Playing information
  (what Control Center shows) can only be read by Apple-signed processes. Deskset does not work around this restriction
  (for example through an Apple-signed helper such as `osascript` or `perl`), because it circumvents a platform privacy
  restriction Apple can close at any time.
- **Why:** no public API; the private one is restricted by the system.
- **Skin impact:** while only such a player plays, NowPlaying measures are empty and skins show their placeholder.
- **Status:** not supported

#### NowPlaying: `PlayerType` values
- **Windows:** Artist, Album, Title, Number, Year, Genre, Cover, File, Duration, Lyrics, Position, Progress, Rating,
  Repeat, Shuffle, State, Status, Volume.
- **Mac:** all of them. Duration / Position `MM:SS` (`H:MM:SS` from one hour, judgment call), interpolated between
  polls; Rating = Music's stars (Spotify has none: 0); Status = 1 while the app runs; Genre, Year, Lyrics: Music only;
  File = the track's file path ("" for streams); `CoverPath` accepted as a synonym; automatic MaxValue for Progress,
  Volume, Rating, State and Position / Duration.
- **Why:** macOS player data.
- **Skin impact:** identical for Music.app; Spotify lacks genre / year / lyrics / rating (as on Windows).
- **Status:** identical (Music) / partial (Spotify)

#### NowPlaying: lyrics and cover art
- **Windows:** lyrics are downloaded from a lyrics website; Cover is a path to an image file.
- **Mac:** lyrics are the ones stored with the track in Music.app (no web lookup). Covers (Music's artwork or
  Spotify's artwork URL) are written to `~/Library/Caches/Deskset/NowPlaying/` with a new file name per track; "" while
  there is no cover, so `Substitute="":"#@#NoCover.png"` works. A local file's cover is Music's artwork. For tracks
  streamed from Apple Music, Music's artwork arrives seconds late or not at all and right after a track change is often
  the previous track's picture, so they are looked up at once with Apple's public iTunes Search API (artist + title;
  the user's storefront, then Taiwan for Chinese names or the US; romanized and Traditional/Simplified names match;
  the title or album must match too, so another song of the artist is never shown).
  Music's artwork is the fallback: asked for over 30 s, a picture it gave for another album's track is ignored, and
  its picture is checked again later. The lookup sends the artist and title of the playing track to Apple — for
  streamed tracks and files without artwork, only while a skin shows a cover. Off with
  `defaults write app.deskset.Deskset OnlineCoverLookup -bool NO`; `NowPlayingDebug` logs every cover step.
- **Why:** no scraping of a third-party site; players hand out data, not files; Music's artwork of streamed tracks is
  late, missing or stale.
- **Skin impact:** lyrics are empty for tracks without embedded lyrics and for Spotify; covers of streamed tracks
  appear about 1–3 s after the track changes.
- **Status:** partial (lyrics) / identical (cover; emulated for streamed Apple Music tracks)

#### NowPlaying: polling, TrackChangeAction, PlayerPath, commands
- **Windows:** each update reads the player; TrackChangeAction on a new track; PlayerPath launches the player;
  Play, Pause, PlayPause, Stop, Next, Previous, OpenPlayer, ClosePlayer, TogglePlayer, SetPosition, SetRating,
  SetShuffle, SetRepeat, SetVolume.
- **Mac:** one shared background poller, once a second, only for running players and only while a skin needs data
  (paused after 30 s without readers); values appear one update after loading. TrackChangeAction runs on a real track
  change (not for the first track, not on stop). PlayerPath is used only when it names a Mac `.app`. All commands work;
  Spotify: Stop = pause, no ratings; playback commands never launch a closed player.
- **Why:** Apple Events are slow and must never block the skins.
- **Skin impact:** data can be up to one second old (position is interpolated).
- **Status:** emulated

#### NowPlaying: strings between the measure's updates
- **Windows:** GetString is called on demand; when a NowPlaying string is refreshed between the measure's own updates
  is not documented, but song-information skins rely on it (Monstercat Visualizer reads its title every 10–20 s and
  shows a new track at once).
- **Mac:** NowPlaying, iTunesPlugin and WebNowPlaying strings read by meters, section variables and Lua are the
  player's current data, Substitute included; the number, IfConditions, IfMatch, OnChangeAction and TrackChangeAction
  follow the measure's updates. A disabled or paused measure keeps the string meters last saw. Judgment: every string
  follows the player, whatever the UpdateDivider.
- **Why:** a new track would otherwise show 10–20 s late in such skins.
- **Skin impact:** title, artist and cover follow a track change within about a second; position strings change every
  second even on a measure updated every few seconds.
- **Status:** emulated

#### iTunes plugin (deprecated `iTunesPlugin`)
- **Windows:** `Command=Get…` values and bang commands for iTunes; DefaultArtwork.
- **Mac:** the same values and commands from Music.app (or Spotify, by the "whichever is playing" rule);
  Bitrate, BPM, SampleRate, Size, Comment, Composer, EQ come from Music only; Power = open / quit; ToggleiTunes hides or
  shows Music; `Command=<bang>` measures run their bang for `!CommandMeasure M ""` and the old `!PluginBang`;
  DefaultArtwork is the placeholder returned when a track has no cover (judgment call).
- **Why:** iTunes became Music.app.
- **Skin impact:** old iTunes skins (PogPack's music tabs) work with Music.app.
- **Status:** identical

#### WebNowPlaying (third-party)
- **Windows:** a browser extension sends web players' media (YouTube, SoundCloud, Spotify web…).
- **Mac:** the browser extension is not supported (a compatibility note says so); the measures show Music.app / Spotify
  instead. All PlayerTypes and
  bangs work (Player = "Music" / "Spotify"; the Repeat bang cycles off → all → one; thumbs up / down set 5 / 1 stars).
- **Why:** the extension protocol is not publicly documented; web media is not readable without private APIs.
- **Skin impact:** WebNowPlaying skins work as Music / Spotify widgets, not for browser media.
- **Status:** partial

#### MediaKey
- **Windows:** sends multimedia keys: NextTrack, PrevTrack, Stop, PlayPause, VolumeMute, VolumeDown, VolumeUp.
- **Mac:** with the Accessibility permission (which Deskset never requests), real media-key events are posted, reach
  whatever app plays and show the volume HUD. Without it (the default), track keys go to Music / Spotify via
  Automation and volume keys change the default output device directly (±2 % per key, mute toggles, raising the
  volume unmutes; no HUD). Stop always goes to the player (Mac keyboards have no Stop key). Also accepted: `Next`,
  `Prev`, `Previous`, `PreviousTrack`, `Play`, `Pause`, `Mute`.
- **Why:** posting keyboard events requires Accessibility on macOS.
- **Skin impact:** without Accessibility the track keys control only Music / Spotify (not browsers).
- **Status:** emulated

### 10.5 WiFiStatus

#### SSID and LIST (Location Services)
- **Windows:** SSID of the current connection; LIST of visible networks (styles 0–7, limit).
- **Mac:** CoreWLAN. macOS returns network names only to apps with **Location Services** permission, asked the first
  time an SSID / LIST measure loads; without it SSID and LIST are empty. No "connecting…" state. The list comes from
  the system's latest scan (Deskset forces an active scan only once, then at most every 5 minutes — scanning disturbs
  calls and games); one line per SSID, strongest first; quality written `[80%]`.
- **Why:** macOS privacy; scanning is slow and disruptive.
- **Skin impact:** a Location Services prompt; the list can lag a few minutes behind reality.
- **Status:** emulated

#### Quality, TXRate, RXRate, Encryption, AUTH, PHY, WiFiIntfID
- **Windows:** quality in percent, TX / RX rates, cipher, authentication, PHY type, interface index.
- **Mac:** Quality = 2 × (RSSI + 100) clamped to 0–100 (judgment call); TXRate = link rate; **RXRate = TXRate**
  (macOS reports one rate); Encryption / AUTH mapped from macOS's combined security mode (rare Windows values never
  appear); PHY 802.11a/b/g/n/ac/ax/be; values refreshed off the main thread at most every 2 s and appear one measure
  update after loading.
- **Why:** CoreWLAN exposes RSSI, one rate and a combined security mode.
- **Skin impact:** RXRate equals TXRate; a measure with a large UpdateDivider shows 0 until its second update.
- **Status:** emulated (RXRate partial)

### 10.6 InputText

#### The input box
- **Windows:** a free-floating edit box at the measure's X / Y / W / H; incompatible with Stay Topmost skins.
- **Mac:** a native text field in a borderless non-activating panel over the skin: the app you were in stays in front
  and gets the keyboard back. It follows the skin if it moves. Judgment calls: TopMost unset = just above the skin;
  missing W = the rest of the skin's width; missing H = the font's line height + 6.
- **Why:** skin windows cannot host a text field.
- **Skin impact:** works on Stay Topmost skins, unlike Windows.
- **Status:** emulated

#### Options, keys, commands
- **Windows:** SolidColor, FontColor, FontFace, FontSize, StringStyle, StringAlign, DefaultValue, Password,
  InputLimit, InputNumber, TopMost, FocusDismiss, OnDismissAction; Enter submits, Escape dismisses, Ctrl+Enter new
  line; `$UserInput$`, `ExecuteBatch`.
- **Mac:** all options (read when the bang runs; fonts resolved like String meters). Ctrl+Enter or Option+Enter
  inserts a line break (one character). FocusDismiss=1: clicking elsewhere or ⌘Tab dismisses; FocusDismiss=0: clicks
  in Deskset's windows are swallowed, but clicks in other apps cannot be blocked on macOS. Batches ask all inputs first,
  then run all commands; Escape cancels the whole batch and runs OnDismissAction.
- **Why:** macOS cannot disable the mouse globally.
- **Skin impact:** minor.
- **Status:** emulated

### 10.7 Window, desktop and color plugins (third-party)

#### FrostedGlass
- **Windows:** DWM accent behind the whole skin window: Blur, Acrylic, Mica, MicaAcrylic, MicaAlt, Backdrop…; corners
  and borders on Windows 11.
- **Mac:** macOS vibrancy (NSVisualEffectView) in a child window behind the skin, following its frame, level and
  alpha. Blur → HUD material, Acrylic → popover + tint, Mica → under-window background, MicaAcrylic → sidebar + tint,
  MicaAlt → window background; Backdrop types = a plain color. Rounded corners 8 / 8 / 4 points clip the skin too;
  square borders have no shadow; DarkMode forces the dark appearance; MicaOnFocus shows the flat material while the
  skin is not the key window; `Effect=` is ignored; "Reduce transparency" turns the blur solid. All commands work.
  `!DisableMeasure` keeps the effect until refresh (use `DisableBlur`).
- **Why:** macOS has no DWM accents; materials are the native equivalent.
- **Skin impact:** the look is close but not identical; the blur is not visible in `--render` images; during a fade the
  blur fades in steps.
- **Status:** emulated

#### Chameleon
- **Windows:** colors from the wallpaper (`Type=Desktop`) or an image (`Type=File`): Background1/2, Foreground1/2,
  Light1–4, Dark1–4, Average, Luminance.
- **Mac:** the wallpaper of the skin's screen (a folder of rotating wallpapers → its first image) or the file,
  sampled in the background when it changes. Colors come from Deskset's own clustering (the plugin's algorithm is not
  documented). ContextAwareColors and ForceIcon are ignored; dynamic / aerial wallpapers that are not image files give
  the fallback colors.
- **Why:** no access to the plugin's method.
- **Skin impact:** colors are similar in spirit, not identical.
- **Status:** emulated

#### IsFullScreen
- **Windows:** 1 when the focused window is full screen; string = its process name (`chrome.exe`).
- **Mac:** 1 when the frontmost app's window covers the primary display (native full screen and borderless games; a
  "zoomed" window is not full screen); string = the app's executable name (`Safari`). No permission needed.
- **Why:** macOS names apps differently.
- **Skin impact:** `IfMatch=chrome.exe` tests never match; full-screen detection works.
- **Status:** partial

#### GetActiveTitle
- **Windows:** the focused window's title.
- **Mac:** the window title with Accessibility (or the window name with Screen Recording) — neither is requested by
  Deskset; otherwise the frontmost app's name.
- **Why:** window titles are private data on macOS.
- **Skin impact:** shows the app name unless the user grants a permission.
- **Status:** partial

#### SysColor
- **Windows:** Windows system colors (accent, window, highlight, button face, …).
- **Mac:** mapped to macOS semantic colors for the current light / dark appearance (accent → accent color, highlight →
  selected content background, window → window background, text → label color, …); `DWM_OPAQUE_BLEND` = 1 when
  "Reduce transparency" is on.
- **Why:** Windows color slots do not exist on macOS.
- **Skin impact:** accent-colored skins follow the Mac accent color.
- **Status:** emulated

---

## 11. WebParser and the skin installer

### 11.1 WebParser

WebParser follows the manual; the regular expressions are PCRE patterns translated to ICU (see
[Actions, bangs, Substitute and regular expressions](#actions-bangs-substitute-and-regular-expressions)). The notes
below come from the implementation notes of the WebParser work and its review, checked against the current code.

#### Values of parents and children (judgment calls)
- **Windows:** the manual does not say what `StringIndex=0`, an empty RegExp or a failing child give, nor how a string
  becomes a number.
- **Mac:** StringIndex 0 (the default) is the whole match; without a RegExp the whole text is the value; the number is
  the leading number of the string ("23.5°C" → 23.5). A child whose RegExp fails keeps its old value, like a parent; a
  StringIndex pointing at a capture that does not exist empties that child and everything below it (the lookahead
  tip's "null value"). All values of a tree are set before any action runs.
- **Why:** the manual is silent.
- **Skin impact:** none for skins that work on Windows.
- **Status:** identical (judgment calls)

#### Disabled and paused children (judgment call)
- **Windows:** "The values of child WebParser measures are a function of the parent measure, and are only updated when
  the parent is"; the manual does not say what a child that is disabled or paused at that moment gets. Skins enable a
  child in the parent's FinishAction (Monstercat Visualizer's update checker does) and expect it to show what the
  parent has just read.
- **Mac:** such a child still gets its values when the parent reads the resource (a `Download=1` child still
  downloads) and shows them at its first update once it runs again. A WebParser measure that is disabled or paused
  when the skin loads still reads its own options once, so that its parent knows it; options changed while it is
  disabled are read when it runs again and apply from the parent's next read, like `!SetOption` on a child.
- **Why:** the manual is silent; this is what such skins need.
- **Skin impact:** none for skins that work on Windows.
- **Status:** identical (judgment call)

#### Actions and errors
- **Windows:** FinishAction, OnRegExpErrorAction, OnConnectErrorAction, OnDownloadErrorAction.
- **Mac:** each measure with a RegExp or `Download=1` runs its own actions; plain children run none. A failed
  connection runs OnConnectErrorAction; for page fetches any HTTP response counts as connected (a 404 body is parsed
  and the RegExp usually fails → OnRegExpErrorAction); for downloads an HTTP error runs OnDownloadErrorAction.
- **Why:** follows the manual's OnRegExpErrorAction text.
- **Skin impact:** none expected.
- **Status:** identical

#### Network behaviour
- **Windows:** default User-Agent "Rainmeter WebParser plugin"; flags such as IgnoreCertName / IgnoreCertDate; a global
  `[WebParser]` section in Rainmeter.data.
- **Mac:** the default User-Agent is "Deskset WebParser" (skins can set their own `UserAgent`). IgnoreCertName and
  IgnoreCertDate are refused — certificate checks stay on — and listed as compatibility notes. HTTP → HTTPS redirects
  are always followed, HTTPS → HTTP only with IgnoreHTTPRedirect; ProxyServer without a port uses 80; the global
  `[WebParser]` section is not supported. Plain `http://` URLs work. URLs are encoded more thoroughly than the
  manual lists (to avoid double encoding by macOS).
- **Why:** the product must not present itself as Rainmeter; certificate checks protect users.
- **Skin impact:** skins that rely on invalid certificates cannot fetch those pages.
- **Status:** emulated / partial (certificate flags)

#### Text decoding
- **Windows:** `CodePage`, `DecodeCharacterReference`, `DecodeCodePoints`.
- **Mac:** CodePage=0 detects a byte-order mark, then valid UTF-8, then the HTTP charset, then the ANSI fallback;
  character references use the HTML 4 names plus `&apos;` (numeric 128–159 read as Windows-1252).
- **Why:** leniency for real web pages.
- **Skin impact:** none expected.
- **Status:** identical

#### Local files, `Debug2File`, `UpdateRate`
- **Windows:** `file://` may read any path; Debug2File writes a dump; UpdateRate counts updates between fetches.
- **Mac:** in the app, `file://` may read only files inside the Skins folder and Deskset's settings folder
  (`#SETTINGSPATH#`), after following links; other paths behave like missing files (logged). Debug2File must be
  inside the Skins folder (else `WebParserDump.txt` in the skin folder), written as UTF-8. UpdateRate ≤ 0 fetches once
  and then only on `!CommandMeasure … Update`.
- **Why:** a skin that reads private files could send them elsewhere in another WebParser's URL.
- **Skin impact:** skins that parse files outside the Skins folder get nothing.
- **Status:** partial

### 11.2 Skin installer

Deskset installs more kinds of packages than Rainmeter does, so older skins can be installed in one step. Details:
[`compat/installer.md`](compat/installer.md).

| Input | Rainmeter (Windows) | Deskset (Mac) |
| --- | --- | --- |
| `.rmskin` made by the Skin Packager (ZIP + footer + `RMSKIN.ini`) | installed | installed |
| `.rmskin` with the footer but without `RMSKIN.ini` | refused | refused (unless it holds a `Rainstaller.cfg`) |
| Legacy Rainstaller `.rmskin` (no footer, `Rainstaller.cfg`) | refused since 2.3 / 2.4 | installed |
| Plain ZIP renamed `.rmskin`, or a `.zip`, with `RMSKIN.ini` | refused since 2.3 | installed |
| Plain ZIP without a manifest | manual installation | installed (root configs detected) |
| An extracted folder | manual installation | installed (copied, never moved) |
| A download ZIP that wraps one `.rmskin` | extract, then install | installed in one step |
| A ZIP holding several `.rmskin` files | extract, install each | refused, naming the packages |
| `.rar`, `.7z` | manual installation | not supported — extract first, then install the folder |

#### Opening packages in the app
- **Windows:** double-clicking a `.rmskin` runs the Skin Installer; other formats are installed by hand.
- **Mac:** `.rmskin` files, ZIP archives and folders can be double-clicked (`.rmskin` only — Deskset is its default
  app), opened with "Open With → Deskset", dropped on the app icon or the Manage window, or chosen with Install Skin….
  Deskset never becomes the default app for ZIP archives or folders. Several items are installed one after another. A
  folder that is, contains or lies inside the Skins folder is refused before anything is copied (skins placed there
  by hand appear after Refresh All).
- **Why:** most download sites hand out ZIPs or folders.
- **Skin impact:** skins that need "extract into Documents\Rainmeter\Skins" on Windows install with one click.
- **Status:** emulated

#### The confirmation and what happens after installing
- **Windows:** the Skin Installer shows the header image, name, author, version, skins, layouts and plugins; the old
  version is backed up and replaced, and the package's skin or layout is loaded.
- **Mac:** an alert shows the header image, "Install “Name”?", author and version; for a plain archive or folder a
  note that the skins were found automatically (a folder is copied, the original stays), for a legacy package a note
  saying so; the root configs and whether they replace (backed up) or add to installed ones; layouts (saved, not
  applied); the fonts the installation adds ("not installed system-wide"); what loads afterwards; Windows plugins
  (never installed) and other warnings. Running skins of a replaced root config are stopped first and loaded again
  afterwards; the package's skin is loaded with a fade and selected in the Manage window.
- **Why:** —
- **Skin impact:** none.
- **Status:** emulated

#### Package formats (plain ZIPs, footer, wrapper folders)
- **Windows:** "As of version 2.3, Rainmeter will not install a normal ZIP file changed to the .rmskin extension";
  the packager puts `RMSKIN.ini` at the top.
- **Mac:** a file without the footer is accepted when it is a ZIP (with RMSKIN.ini, with Rainstaller.cfg, or with
  neither); a file *with* the footer must contain a manifest (a missing one means a damaged package). The manifest is
  looked for at the top and below up to three single wrapper folders (loose read-me or preview files beside them do
  not matter). Bytes between the ZIP and the footer are ignored.
- **Why:** many packages on skin sites are hand-zipped or made for the old Rainstaller (judgment call).
- **Skin impact:** packages that Rainmeter 4 refuses install on the Mac.
- **Status:** emulated

#### Extraction safety
- **Windows:** not documented.
- **Mac:** before anything is written the ZIP directory is checked: absolute paths, drive letters, `..`, NUL bytes
  and symbolic links are refused, as are archives over 200 000 entries or 4 GB; extraction is watched for ZIP bombs
  (300 s timeout). Links, special files and `__MACOSX` are removed; names with `\` become folders; non-UTF-8 names
  are read as code page 437; the download's quarantine flag is passed on so Gatekeeper keeps checking anything a skin
  launches. A ZIP that lists no `.ini` (and no `Rainstaller.cfg` or wrapped `.rmskin`) is refused before extraction.
- **Why:** macOS security; skins never need links.
- **Skin impact:** a package containing symbolic links (even harmless ones) is refused. Very old packages may show odd
  characters in folder names on Macs set to some languages.
- **Status:** emulated

#### Hidden files
- **Windows:** "The Skin Packager will ignore any hidden files or folders".
- **Mac:** names starting with `.`, `__MACOSX`, and Windows' hidden `desktop.ini`, `Thumbs.db`, `ehthumbs.db` are never
  installed; backups keep everything.
- **Why:** same rule; ZIPs made on macOS and Windows carry such debris.
- **Skin impact:** none.
- **Status:** identical

#### RMSKIN.ini and the header image
- **Windows:** the manual documents the packager's fields but not the key names; the header must be a 400×60 `.bmp`;
  the installer refuses packages whose minimum Rainmeter / Windows version is not met.
- **Mac:** `[rmskin]` keys Name, Author, Version, LoadType, Load, VariableFiles, MergeSkins (also `Merge`),
  MinimumRainmeter, MinimumWindows (UTF-8 / UTF-16 / ANSI). **Minimum versions are not enforced.** `RMSKIN.bmp` is shown
  when it is a real bitmap of at most 4096 px (exact size not required).
- **Why:** Windows versions mean nothing on macOS; unsupported features are reported by the engine instead.
- **Skin impact:** packages made for a newer Rainmeter install; unsupported features degrade.
- **Status:** identical / not supported (minimum versions)

#### Root configs, backups and Merge skins
- **Windows:** one root config per package; existing skins are "moved to a Backup folder"; with Merge skins
  "the root config folder is not removed or backed up".
- **Mac:** every folder in `Skins/` (except `@Vault`) is installed as a root config. An existing root config is moved
  to `Backups/<RootConfig>` (then `(2)`, `(3)`… so older backups are kept); the new folder is staged and swapped in,
  and the old one is put back if the swap fails. With `MergeSkins=1` the package is copied over the existing folder
  without deleting anything, and a full copy of the old folder is also kept in Backups (judgment call).
- **Why:** hand-made and legacy packages often hold several root configs; a backup lets users undo an add-on.
- **Skin impact:** suites split over several root configs install completely; an extra folder in Backups.
- **Status:** emulated

#### Variables files
- **Windows:** existing variable values are kept; Merge skins takes precedence; without a backup the option is skipped.
- **Mac:** for each listed file present in both versions, every `[Variables]` key present in both keeps the user's
  value exactly as written; the package file keeps its layout, comments, new keys and encoding; `@Include…` lines
  always come from the new version. Values are kept even with MergeSkins or without a backup (Rainmeter skips them).
- **Why:** keeping the user's settings is never worse.
- **Skin impact:** none.
- **Status:** emulated

#### Plugins, add-ons and `@Vault`
- **Windows:** plugin DLLs go to the Plugins folder and are archived in `@Vault`; legacy `Addons\` programs are
  installed.
- **Mac:** DLLs are never installed or archived; the confirmation lists them and warns that skins using them show no
  data. Add-on programs are never installed (noted). A package's `@Vault` is merged into `Skins/@Vault` without
  replacing files.
- **Why:** Windows DLLs and programs cannot run on macOS.
- **Skin impact:** parts of skins that rely on unsupported plugins stay empty; buttons that launch add-on tools do
  nothing.
- **Status:** not supported (plugins, add-ons) / partial (`@Vault`)

#### Layouts and loading after installation
- **Windows:** layouts go to the Layouts folder and can be applied; the author may choose a skin or layout to load.
- **Mac:** layouts are installed with their `[Rainmeter]` options removed but **not applied yet** (the app says so).
  `LoadType=Skin` + `Load=Config\File.ini` loads that skin when it was installed from this package.
- **Why:** layouts are not implemented in the app yet.
- **Skin impact:** suites that arrange themselves with a layout install, but the user loads the skins by hand.
- **Status:** partial

#### Fonts
- **Windows:** legacy packages' `Fonts\` folder was installed into `Windows\Fonts` (no longer since 2.4); only
  `@Resources\Fonts` is loaded automatically; a font next to the skins must be installed by the user.
- **Mac:** TrueType / OpenType fonts from the package's `Fonts/` folder, loose at the top of the package, in a root
  config's own `Fonts/` folder, or loose next to its `.ini` files are copied into that root config's
  `@Resources/Fonts` (never replacing an existing font). Nothing is installed system-wide. Windows bitmap (`.fon`,
  `.fnt`) and Type 1 fonts are not installed.
- **Why:** the manual step a Windows user would do, done automatically; system-wide installation would change every
  app's font list (judgment call).
- **Skin impact:** eClock, HDD Usage Bars, Elegant Watch, Mnml Drives and PogPack show their intended fonts without a
  manual step. The fonts are not available to other Mac apps.
- **Status:** emulated

#### Legacy Rainstaller packages
- **Windows:** used by Rainstaller (Rainmeter 1.x–2.3); current Rainmeter refuses them.
- **Mac:** `Rainstaller.cfg` is read like RMSKIN.ini: Name, Author, Version, `MinRainmeterVer` (not enforced),
  `Merge=1`, `KeepVar` (keeps the user's variables in every `.ini` / `.inc`, or in a listed set of files),
  `LaunchType` / `LaunchCommand` (Theme / Layout → load a layout; Load / Skin / Config or a bang such as
  `!ActivateConfig` → load a skin; running programs is never done). `Themes\<name>\Rainmeter.thm` becomes a layout.
  `AdminRights` and `RainmeterFonts` are ignored.
- **Why:** the keys are undocumented; the mapping follows their names and real packages (judgment call).
- **Skin impact:** legacy packages install with their name, version, merge and load settings.
- **Status:** emulated

#### Plain archives and folders (no manifest)
- **Windows:** manual installation: extract, locate the skin folder (maybe inside a `Skins` folder), move it to
  Skins, refresh.
- **Mac:** the same steps, automated: a `Skins` folder (at the top or under up to three wrapper folders) makes the
  archive a package; an archive whose top has `.ini` files or `@Resources` is one root config named after the
  archive; otherwise each top folder with skins is a root config (a single folder is taken as a wrapper only when a
  folder below it has `@Resources` or is named by the skins' `#SKINSPATH#Name\` paths). Read-me files and previews
  outside root configs are left out. With exactly one skin it is loaded after installing. A folder is copied, never
  moved; a folder inside the Skins folder is refused. Reinstalling from a plain archive replaces the root config like
  a `.rmskin` without Variables files: the old version, with any settings the user changed in its files, goes to
  Backups.
- **Why:** judgment call; the manual only says the folder may be nested.
- **Skin impact:** most "extract to Skins" archives install correctly. Known misreadings (the skins still run, only
  their config names differ): a wrapper without `@Resources` or `#SKINSPATH#` hints is kept as an extra level; an
  archive of a root config's *contents* without `@Resources` splits into several root configs; a ZIP of a layout
  folder installs as a root config.
- **Status:** emulated

#### Interrupted installation
- **Windows:** not documented.
- **Mac:** if the app is killed mid-install, hidden `.deskset-install-*` / `.deskset-old-*` folders can remain in the
  Skins folder; they are not deleted automatically because `.deskset-old-*` may hold the only copy of a skin.
- **Why:** safety over tidiness.
- **Skin impact:** none (hidden folders are not scanned).
- **Status:** emulated

---

## 12. Real-world test results

Fifteen popular third-party skin packages (390 skin files) were rendered headlessly with the current build on
2026-09-24 and compared with a first round made before Lua, the bundled plugins and the latest engine fixes existed.
The skins were tested locally only; none of them is distributed with Deskset. Raw numbers:
[`compat/retest-2026-09-24.md`](compat/retest-2026-09-24.md).

**Method.** Each skin was loaded, updated 3 times 300 ms apart and drawn to a PNG (`Deskset --render`), 10 at a time,
each with a 30-second limit — once as is and once with generated demo audio and a demo "now playing" track (so
visualizers and player skins show something without a permission prompt). All 15 original downloads were also
installed with the installer into a temporary Skins folder and rendered from there. The main pass used the build
of 2026-09-24 before the app and engine wiring were merged; a second pass with both merged gave the same picture (see
the last row of the table).

### 12.1 Numbers

| | First round | Now |
| --- | --- | --- |
| Skin files rendered | 390 | 390 |
| Crashes / timeouts | 0 / 0 | 0 / 0 (also 0 / 0 with demo audio, and 0 / 0 for the 390 installed copies) |
| Compatibility notes (lines) | 614 | 9 |
| Skins with at least one note | 339 | 6 |
| Error lines in the skin logs | 20 | 6 (skin mistakes, dead web services, and PogPack rendered from its extracted folder without installing it) |
| Packages the installer accepts | 13 of 15 | 15 of 15 |
| With the app and engine wiring merged | — | 390 of 390 rendered, 0 crashes / timeouts (also with demo audio); 11 notes in 8 skins: the 9 above plus 2 new notes that the skins' Winamp player has no Mac version; no spurious MeterStyle warnings |

Compatibility notes by cause:

| Note | First round | Now |
| --- | --- | --- |
| Lua scripts (`Measure=Script`) not supported | 286 | 0 |
| MeterStyle does not exist (skin mistakes, now log lines only) | 182 | 0 |
| InputText not supported | 41 | 0 |
| CoreTemp Windows-only | 20 | 0 |
| FrostedGlass Windows-only | 17 | 0 |
| WiFiStatus Windows-only | 12 | 0 |
| NowPlaying not supported | 11 | 0 |
| Win7AudioPlugin Windows-only | 8 | 0 |
| RecycleManager Windows-only | 7 | 0 |
| Registry Windows-only / value not available | 6 | 2 (two video-memory values) |
| PingPlugin not supported | 5 | 0 |
| PerfMon Windows-only / counter not available | 3 | 1 (`Current Bandwidth`) |
| PowershellRM (third-party Windows plugin) | 3 | 3 |
| ActiveNet (third-party Windows plugin) | 2 | 2 |
| AudioLevel, iTunes, ActionTimer, AdvancedCPU, QuotePlugin, RunCommand, UsageMonitor, SysInfo `DOMAINWORKGROUP` | 10 | 0 |
| MSI Afterburner (third-party Windows plugin) | 1 | 1 |

### 12.2 Package by package

| Package (skins) | Result now | What still differs, and why |
| --- | --- | --- |
| **CoreLoads** (1) | Per-core loads and graphs work (were empty) | Temperature reads 0 (no sensor API). The empty lower half is the skin's own design (cores 3–6 are commented out). |
| **Elegant Watch** (1) | Correct time (hands were stuck at 12); its font installs with the package | None |
| **EasyInfo** (1) | Full layout with its colors (was grey with wrong colors): LED clock, CPU bars and graphs, memory, disk | CPU frequency reads 0.000 GHz (Apple silicon has no public frequency API); core temperatures 0 (no sensor API); its "Digital-7 Mono" font is not in the package, so the LED digits use a fallback font (also on Windows without that font). |
| **Enigma** (308) | Lua-driven parts now work: month and week calendars, notes, feed readers' status, taskbar widths and alignments, clocks, volume, now playing, Trash count, Wi-Fi quality, top processes, picture gallery (from `~/Pictures`) | Weather, location, sunrise / sunset and world-city data stay empty because the Yahoo weather service the skins use no longer exists (same on Windows). Feed readers need the user's feed URLs. Launchers point at Windows programs. The external IP appears once its web request returns (~2 s). |
| **FluentDash11** (17) | CPU and GPU name ("Apple M4 Pro"), no more collapsed rows, settings buttons, network, RAM, disks, system info; frosted glass | CPU speed 0.0 GHz and temperatures 0 °C (no public API); GPU clock, VRAM and fan empty (MSI Afterburner plugin); GPU usage 0 %; adapter rows of the 2- and 3-adapter network skins overlap (they rely on the PowershellRM plugin, and the skin sets text on a meter name that does not exist); D:, E:, F: repeat the startup disk. |
| **HDD Usage Bars** (4) | The three-drive variant now shows three drives in the right places; with the installer its pixel font installs and the result matches the author's screenshot | Every drive letter shows the startup disk. |
| **HMNmeter2 / Network Meter** (3) | Live rates, peaks and totals (were empty), ping, external IP (after ~2 s) | ActiveNet (Windows plugin) → MAC address and adapter details stay "Asking Hardware"; `Current Bandwidth` reads 0; the IP-location service returns nothing; the skin's Windows adapter name falls back to the active interface. |
| **Mini Weather** (1) | Unchanged | No weather: the weather.com XML service it uses was shut down (same on Windows). |
| **Mnml Drives** (2) | Works; the legacy Rainstaller package now installs, with its pixel font | Drive letters show the startup disk. |
| **Nelamint** (13) | Player (track, cover), visualizer, CPU, RAM, disks, clock, links, settings | Weather empty (weather.com XML service shut down); Wi-Fi reads 0 in a 3-update test because of its `UpdateDivider=4` (fills in the app). |
| **PogPack 1.3** (26) | The legacy package now installs as the root config `PogPack` with its three fonts and its theme as a layout; installed, every tab shows its art, fonts and values (system, battery, garbage, signal, volume, music controls) | The layout is not applied yet; the Windows add-on (configuration tool) is not installed; weather is empty (the weather.com XML service was shut down); the music minute counter shows nothing because the skin's formula names a meter instead of a measure (skin bug, same on Windows); the music tabs show data only while Music or Spotify runs. |
| **Simple Clean** (8) | Greeting with the user's name (showed the raw section variable), player and visualizer, clocks, settings | Weather empty (weather.com XML service shut down); menu entries that launch Windows programs do nothing. |
| **Simplistic Analog Clock** (2) | Correct time (hands were wrong) | None |
| **cpu meter** (1) | Works with its bundled script font | The text is cut off when the CPU value gains a digit after loading: the skin has no `W` or `DynamicWindowSize` (same rule as in Rainmeter). |
| **eClock** (2) | The long shadow is drawn correctly (was scattered); installed with the new installer, its font is copied into `@Resources` and the render matches the author's preview image | Rendered straight from the extracted folder it uses a fallback font, because its font file sits next to the skins (Windows users install it by hand). |

### 12.3 What the remaining differences come from

| Cause | Examples |
| --- | --- |
| Windows-only plugin DLLs | PowershellRM, ActiveNet, MSI Afterburner (FluentDash11, HMNmeter2) |
| Data macOS does not expose | Temperatures, CPU frequency on Apple silicon, GPU usage and clocks, video memory |
| Web services that no longer exist | Yahoo weather (Enigma), the weather.com XML service (Mini Weather, Nelamint, PogPack, Simple Clean) |
| Skin mistakes (same on Windows) | A formula naming a meter (PogPack), "mm" printed twice in an uptime text (Enigma), text set on a missing meter (FluentDash11) |
| Things the user configures | Feed URLs, launcher targets, weather location codes |
| Test-window timing only | Slow web requests (external IP) and large `UpdateDivider` values fill in after a few seconds in the app |

No crash, hang or timeout was found, and no remaining difference was traced to a Deskset rendering bug. The only
engine quirk seen in the main pass — MeterStyle names built from section variables (Enigma's reader and notes tabs)
logging "MeterStyle … does not exist" at load although the style is found and drawn correctly — no longer happens
with the engine wiring merged.

---

## 13. Known gaps and what is planned

| Gap | Status | Notes |
| --- | --- | --- |
| Hardware sensors (temperatures, fans, voltages, GPU clocks) | not supported | macOS has no public API; planned for a later version |
| Layouts (`!LoadLayout`, applying installed layouts) | not supported | Installed layouts are kept for when this ships |
| Aero blur (`Blur`, `BlurRegion`, blur bangs), `!ResetStats` | not supported | Use FrostedGlass for blur |
| Stored window anchors (`!SetAnchor`; saved positions keep an anchor) | partial | Anchors are applied once when a skin is placed; a resizing skin grows to the right and down |
| `DragGroup`; the Ctrl / ⌘ override on click-through skins | not supported | Turn click-through off from the menu or the Manage window |
| Custom cursors (`.cur` / `.ani`, most cursor names) | partial | The arrow is shown |
| WindowMessage, VirtualDesktops | not supported | No macOS counterpart |
| Other Windows plugin DLLs | not supported | Values 0 / empty, a note in the skin's Compatibility Notes |
| Per-app volume (AppVolume `SetVolume`) | not supported | macOS has no per-app volume |
| Browser media (WebNowPlaying extension) | not supported | Music and Spotify are shown instead |
| Lua `os.execute` shell commands | partial | `os.execute` only opens files and URLs; use RunCommand |
| `.rar` / `.7z` packages | not supported | Extract first, then install the folder |
| Windows icon fonts (Segoe MDL2 / Fluent Icons) | not supported | Ship an icon font or images in `@Resources` |
| Exotic PCRE features (recursion, backtracking verbs) | partial | Common patterns work |

---

## 14. Sources and method

- The Rainmeter manual: <https://docs.rainmeter.net/manual/> (skins, variables, formulas, meters, measures, plugins,
  bangs, distributing and installing skins), its tips pages and the version history.
- Public READMEs and usage pages of third-party plugins (AppVolume, WebNowPlaying, FrostedGlass, Chameleon, SysColor,
  IsFullScreen, GetActiveTitle, Mouse and its version 2, Slider).
- Apple documentation for Core Audio, CoreWLAN, AppKit, ScreenCaptureKit and AppleScript dictionaries of Music and
  Spotify.
- Observation of real skins and their authors' screenshots, tested locally only.

Deskset is a clean-room implementation: no Rainmeter or plugin source code was read or used. "Rainmeter" is a
trademark of its owners; Deskset is an independent product that is compatible with Rainmeter skins.

Per-area notes, updated as the code changes: [`compat/engine.md`](compat/engine.md), [`compat/lua.md`](compat/lua.md),
[`compat/plugins.md`](compat/plugins.md), [`compat/audio.md`](compat/audio.md), [`compat/media-ui.md`](compat/media-ui.md),
[`compat/installer.md`](compat/installer.md) and [`compat/app.md`](compat/app.md). These files and this document
describe the current behaviour.
