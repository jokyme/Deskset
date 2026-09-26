# Engine: skins, meters, measures and drawing (Mac vs Windows)

Scope: the skin runtime in `Sources/DesksetCore/Engine` (update cycle, layout, options, built-in measures and
meters, bangs the engine performs) and the drawing code in `Sources/Deskset` (`SkinRenderer`, `Renderers/*`,
`Fonts`, `Images`). Lua, plugins, audio, WebParser and the installer have their own files.

Everything here comes from the public manual (https://docs.rainmeter.net/manual/, the tips pages and the version
history) and from observing real skins and their authors' screenshots — never from Rainmeter's source code.
"Evidence" names the skins of the local compatibility corpus that show the behaviour (third-party skins, tested
locally only, not distributed).

Contents: 1. Layout and window size · 2. Text and fonts · 3. Options, skin language and compatibility notes ·
4. Measures · 5. Meters and drawing · 6. Mouse, bangs and actions · 7. Limits · 8. Known differences not fixed.

---

## 1. Layout and window size

### Coordinates and units
- Windows (Rainmeter): X, Y, W, H and font sizes are in screen pixels at 96 DPI (/manual/meters/general-options/).
- Mac (Deskset): one skin pixel is one macOS point. On a Retina screen everything is drawn at 2× (sharper, same
  layout). `#SCREENAREAWIDTH#`, `#WORKAREA…#` and SysInfo screen values are in points too.
- Why: macOS lays windows out in points; mapping pixels to points keeps a skin the same physical size it has on a
  typical Windows desktop.
- Skin impact: layouts match; bitmaps are shown at their pixel size in points (1 px image pixel per point), so
  low-resolution images look as soft as on a 100 % Windows display.
- Status: emulated

### Relative positions (`r` / `R`) after aligned String and Bitmap meters
- Windows (Rainmeter): "If the value is appended with r, the position is relative to the top/left edge of the
  previous meter … R … relative to the bottom/right edge" (/manual/meters/general-options/). StringAlign "is
  always based on the value of X or Y" (/manual/meters/string/). Observed: the following meter is relative to the
  aligned meter's X / Y option (its anchor), and `R` adds W / H to the anchor, not to the moved box.
  Evidence: eClock (a "long shadow" of 20+ right-aligned copies at `X=1r Y=1r`; its Preview.png shows each copy one
  pixel right of and below the previous one), EasyInfo (the LED time at `X=0r Y=0r` over a centered "88:88:88"
  backlight overlaps it exactly), Enigma Sidebar System (a right-aligned label, its value at `X=9r`), FluentDash11
  Settings (rows placed with `Y=17R` after a `StringAlign=CenterCenter` caption are 64 px apart in the author's
  screenshot = caption anchor + H + 17; the moved box would give 50 px).
- Mac (Deskset): the same. `[Meter:X]` / `[Meter:Y]` still report the moved ("real") box, as the Section Variables
  page says ("may be different than the values in the meter options if StringAlign is used"). The same rule applies
  to Bitmap meters with `BitmapAlign` (judgment: the manual describes BitmapAlign like StringAlign). A hidden meter
  has no size and is never moved, so its anchor is its position.
- Why: the manual's anchor rule plus the authors' screenshots; the manual does not spell out r / R for aligned meters.
- Skin impact: right- / center-aligned stacks, shadows and label / value rows line up as on Windows.
- Status: identical (fixed in this round; earlier builds used the moved box, which scattered eClock's shadow and
  shifted every right/center-aligned stack)

### When the window size is computed
- Windows (Rainmeter): "DynamicWindowSize: If set to 1, the window size is adjusted on each update to fit the
  meters"; otherwise it is fixed when the skin loads; `!MoveMeter` re-evaluates it.
- Mac (Deskset): without DynamicWindowSize the size is computed once, at the end of the first update, from every
  visible meter (content meters of a Container do not count) and the `BackgroundMode=0` image. A `!Redraw` /
  `!UpdateMeter` run by an IfCondition / IfAboveAction… while the first update's measures are still updating no
  longer sizes the window early (it used to size it from meters that had not been updated — all String meters
  empty — and the skin stayed cut off; evidence: EasyInfo, whose blinking clock runs `[!Redraw]` from a Calc
  measure). SkinWidth / SkinHeight override the computed size.
- Why: as documented; the early sizing was an engine bug.
- Skin impact: skins whose text grows after load still need DynamicWindowSize or a fixed W, as on Windows.
- Status: identical (the early-sizing bug is fixed in this round)

### Meter geometry before the first update
- Windows (Rainmeter): not documented. The inline Lua page says the main chunk runs "during the initialization phase
  of the skin" and Initialize() "during the first update cycle"; measures update before meters in every update, and
  the Lua manual describes `Meter:GetX()` / `GetW()` as the meter's (real) position and size.
- Mac (Deskset): meters are laid out at the end of the first update's meter pass. Anything that asks for a meter's
  position or size before that — a script's main chunk (it runs while the skin loads), its Initialize() and first
  Update() (`Meter:GetX/GetY/GetW/GetH`, `SetX…` too), `[Meter:X]` / `[Meter:W]` section variables read by
  measures in the first update, by DynamicVariables options while the skin loads, or by a meter in the first
  update's meter pass that names a meter below it (not placed yet in that pass) — first triggers a provisional
  layout from the meters' options: X / Y with `r` / `R`, W / H, Padding, Hidden, Container, image and shape sizes,
  and for String meters the text of Text / Prefix / Postfix with the bound measures' values at that moment (at load
  the initial 0 / "", so a meter bound to a measure shows "0"). The provisional layout never sets the window size:
  without DynamicWindowSize the size is still computed once, at the end of the first update, from the updated meters
  (see above). The first update's own layout replaces every provisional frame. Fixture:
  `TestSkins/Engine/Compat/EarlyGeometry.ini` (its Initialize() reported "title 0x0, badge at x=0" before).
- Why: before this, every frame was 0 until the end of the first update, so scripts that store a meter's position
  or size in Initialize() (animation start points, Enigma's taskbar width script reading `GetW()` in its first
  Update()) and measures computing from `[Meter:X]` in the first update got 0. Judgment call: the manual does not say
  when meter geometry exists; options are known at load, so a layout from them is the closest meaningful value.
- Skin impact: geometry read early matches the options (and static texts); values that depend on measures (String
  meters bound to them) are only right after the first update, as for any first-update reader.
- Status: emulated (judgment call)

### Background image size (`BackgroundMode=0`)
- Windows (Rainmeter): "All general image options are valid for Background"; mode 0 shows the image at its size.
- Mac (Deskset): the window is at least as large as the image after ImageCrop / ImageRotate (and EXIF orientation
  with UseExifOrientation=1) — the size that is drawn. The options are read once when the skin loads.
- Judgment: a skin that sets `Background=` without `BackgroundMode` gets mode 0 (the manual's default is 1,
  transparent, which would make the Background option do nothing).
- Why: the window must hold what is drawn.
- Skin impact: none.
- Status: identical (+ one judgment call)

### Container
- Windows (Rainmeter): content is clipped/masked by the container; containers cannot be nested.
- Mac (Deskset): the same; `[ContentMeter:X]` is in skin coordinates (judgment: the manual is silent). An invalid
  `Container=` (missing meter, itself, nested) is a log line, not a compatibility note — Rainmeter rejects it too.
- Why: as documented.
- Skin impact: none.
- Status: identical

### Window levels (`AlwaysOnTop`)
- Windows (Rainmeter): -2 On Desktop, -1 Bottom, 0 Normal (default), 1 Topmost, 2 Stay Topmost.
- Mac (Deskset): -2 = just above the Finder's desktop icons; -1 = below normal windows, hidden by Show Desktop /
  Mission Control ("will not stay visible when showing the desktop"); 0 = normal level; 1 = floating level (also
  over full-screen apps); 2 = above the Dock, below the menu bar. New skins start On Desktop (-2).
- Why: macOS has no "desktop" window a skin can be pinned to; these levels are the closest equivalents. The -2
  default is a product choice (widgets on a Mac are expected to sit on the desktop).
- Skin impact: `DefaultAlwaysOnTop` / the skin's own setting still apply once chosen.
- Status: emulated

---

## 2. Text and fonts

### Font size
- Windows (Rainmeter): `FontSize` is in points at 96 DPI.
- Mac (Deskset): pixels = FontSize × 96 / 72 (FontSize=10 → 13.33 points of text), so text takes the same room as
  on Windows at 100 % scaling.
- Why: macOS points are 72 per inch; Rainmeter's sizes assume 96 DPI.
- Skin impact: none (sizes match Windows at 100 % scaling).
- Status: emulated

### Font substitution
- Windows (Rainmeter): FontFace names an installed family; Arial when it is missing ("Arial is now the default font
  when FontFace is not specified or errors occur").
- Mac (Deskset): installed / registered family first; then a table of Windows fonts that macOS does not ship (Segoe UI
  and its weights → the system font with Segoe UI's line metrics 2210/514/0 per 2048, so `Y=0R` stacks keep their
  spacing; Calibri → system font; Consolas / Lucida Console → Menlo; Cambria / Constantia → Georgia; Tahoma →
  Verdana; Century Gothic → Futura; Bahnschrift → DIN Alternate; Microsoft YaHei → PingFang SC; Meiryo / Yu Gothic →
  Hiragino Sans; Malgun Gothic → Apple SD Gothic Neo; …); then full / PostScript names ("Fira Sans Bold") and names
  with trailing style words ("Roboto Light Italic" → Roboto 300 italic); finally Arial. Marlett's window-control
  letters (0 1 2 r 3 4 5 6 a) map to Unicode symbols. Segoe MDL2 Assets / Segoe Fluent Icons private-use glyphs
  have no Mac equivalent (fallback font, usually empty boxes).
- Why: those fonts are Microsoft's and are not on a Mac. Only Segoe UI's vertical metrics are copied; the other
  substitutes keep the Mac font's own line height.
- Skin impact: text is a little wider or narrower than on Windows; fixed-width clipping (`ClipString`) may cut at a
  different character. Icon fonts from Windows show nothing.
- Status: emulated / partial (icon fonts: not supported)

### Skin fonts (`@Resources\Fonts`, `LocalFont`)
- Windows (Rainmeter): TrueType / OpenType fonts in the root config's `@Resources\Fonts` "are automatically
  loaded and can be used with the FontFace option"; `LocalFontN=` loads more. Fonts elsewhere in a package (e.g.
  eClock's MazzardH-Bold.ttf at the package root) must be installed by the user.
- Mac (Deskset): the same files are registered for the process before the skin measures any text. On every skin
  load / refresh the folder is read again: fonts added or replaced since are registered (a replaced file is
  registered again), removed ones are unregistered, and skins already on screen are measured again
  (`Skin.fontsDidChange()`: their window size is recomputed once, even without DynamicWindowSize, because the
  first size was measured with a fallback font — this cannot happen in Rainmeter, which loads the fonts first).
- Why: macOS registers fonts per process; a skin's fonts may appear after other skins were laid out.
- Skin impact: fonts added to @Resources\Fonts are picked up by "Refresh skin".
- Status: identical (Mac-only re-measuring when fonts appear later)

### Clipped text in "cpu meter" (investigated)
- Windows (Rainmeter): the window size is fixed when the skin loads unless DynamicWindowSize=1; the CPU measure page
  does not say what the first reading is.
- Observed: "cpu meter" (Rallifornia from @Resources\Fonts, `Text=CPU: %1%.`, CharacterSpacing 1|1, no
  DynamicWindowSize) drew its text past the right edge of the window.
- Root cause: not the font. The measured width equals CoreText's advance width of the text plus the inline
  CharacterSpacing (173.3 + 8 × 2 = 189.3 → 190 px), the script glyphs stay inside their advances, and the font is
  registered before the first measurement. The window width is fixed at the first update, and the first CPU
  reading on the Mac is 0 ("CPU: 0%." is a digit narrower than "CPU: 11%."), so later values are cut off.
- Mac (Deskset): window sizing follows Rainmeter (see §1). The app's first CPU sample is now the average load since
  boot (see CPU in §4), so the first value — and the width fixed from it — is realistic.
- Skin impact: skins whose only text grows after load and that lack DynamicWindowSize / a fixed W can still be cut
  off when a later value is longer; the same happens in Rainmeter whenever the first value is shorter.
- Why: the Mac data source needs two samples for a percentage over an interval; the first one has none.
- Status: identical (fixed by the first-sample change)

### AccurateText
- Windows (Rainmeter): `AccurateText=0` (default) measures text GDI+-style with extra padding; 1 uses Direct2D-like
  metrics.
- Mac (Deskset): 0 adds 1/6 em of horizontal padding on each side (the commonly cited GDI+ value) and insets the
  text by it; 1 uses the CoreText advance width. Line height = ascent + descent + line gap of the tallest run.
  Trailing whitespace is not counted (DirectWrite behaviour) unless `TrailingSpaces=1` at the end of a paragraph.
  Widths / heights are rounded up to whole pixels.
- Why: the exact GDI+ padding is not documented.
- Skin impact: String meters may be a pixel or two wider or narrower than on Windows.
- Status: emulated

### Empty String meters
- Windows (Rainmeter): version history 3.0: "Fixed an issue with Direct2D where a string meter with an empty string
  would still have a width and height" — an empty string has no size.
- Mac (Deskset): an empty text has no size — except when it is empty only because a bound measure has no data on the
  Mac (a Windows plugin DLL no module provides, such as MSI Afterburner, a registry value that is not emulated, a
  SysInfoType without a Mac answer; `Measure.valueUnavailable`):
  then the meter keeps the height of one line of its font (width 0), because on Windows the value would be there.
  Evidence: FluentDash11 CPU / GPU panels, where rows stacked with `Y=5R` below a value from MSI Afterburner (and,
  before the core plugins existed, CoreTemp) collapsed onto each other. Measures of other modules keep the
  Rainmeter rule unless they report `valueUnavailable`.
- Judgment: the round's brief said DirectWrite measures an empty layout as one line; the manual's history entry says
  Rainmeter gives an empty string no size, so that rule is kept for real empty strings.
- Why: on the Mac many values are empty only because a Windows plugin or registry value has no counterpart; letting
  those rows collapse would break layouts that are fine on Windows.
- Skin impact: rows below a missing value keep their spacing; genuinely empty strings behave as in Rainmeter.
- Status: identical (+ Mac-only emulation for unavailable data)

### Anti-aliasing, Angle, clipping and tabs
- Windows (Rainmeter): `AntiAlias=1` smooths text; `Angle` rotates without changing size/position; ClipString
  1/2; tab stops not documented.
- Mac (Deskset): `AntiAlias=0` draws aliased (jagged) text, as the manual says — harsher than users expect on a Mac.
  Angle rotates around the StringAlign anchor, clockwise for positive radians; the SolidColor background is not
  rotated. ClipString=1 wraps only when both W and H are set, otherwise every line gets "…"; ClipString=2 also puts
  "…" on the last visible line when lines are cut by height; a single long word is clipped without "…". Tab stops
  every 4 × the font size (DirectWrite's default). A trailing newline adds no empty line.
- Why: judgment calls where the manual is silent (Angle's centre: the linked forum post is not part of the manual).
- Skin impact: skins without AntiAlias=1 look jagged, as the option asks.
- Status: emulated (judgment calls where the manual is silent)

### Inline options
- Windows (Rainmeter): InlineSetting / InlinePattern (/manual/meters/string/inline/), drawn by DirectWrite.
- Mac (Deskset): every documented InlineSetting is drawn with CoreText. Judgments where the manual is silent:
  CharacterSpacing's leading space before the first character of a line is kept as an indent; a later span of the
  same kind wins where two overlap; GradientColor with "alternative gamma" interpolates in linear light; each match
  of a gradient pattern gets its own gradient box; inline Shadow is clipped to the meter ("the shadow drawing surface
  [is] the size of the meter itself").
- Why: CoreText and DirectWrite shape and space text differently in details.
- Skin impact: small spacing differences; Typography features depend on the Mac font having them.
- Status: emulated

---

## 3. Options, skin language and compatibility notes

### Section variables in options without DynamicVariables
- Windows (Rainmeter): "Section variables are always dynamic. DynamicVariables=1 will always be needed on a measure or
  meter section where the variable is used in an option value" (/manual/variables/section-variables/); the Dynamic
  Cheat Sheet adds that `!SetOption` makes its target "dynamic for one update". The manual does not say what a
  non-dynamic option does with `[Name]`. Observed: skins known to work resolve it once, when the options are read,
  and then keep that value. Evidence: HDD_Usage_Bars (`[MeterIconHover] X=[MeterDiskIcon:X]`, a hidden ring without
  DynamicVariables; the next icon at `X=134r` is 134 px right of the first icon in the author's screenshot, so the
  ring's X was the icon's 1, not 0 — and the three-drive variant would stack two icons otherwise), Mini Weather
  (`X=([Icon:X] + [Icon:W] / 2)` centers the temperature under the icon), HMNmeter2 (mouse regions at
  `X=([Button:X] * #Scale#)`).
- Mac (Deskset): section variables are resolved in every read of a section's options after the skin loaded, and kept
  until the next read: a section without DynamicVariables whose options name a measure or meter (`[Name]`,
  `[Name:X]`, `[&Name]`) reads them once more when the first update reaches it — after the measures were updated
  and the meters above it were placed — and again after a `!SetOption` on it. This includes `MeterStyle`
  (`MeterStyle=StyleButton[MeasureState]`). `[Name]` that names no section stays as written; escapes (`[*Name*]`)
  and character references work as before. A measure reading `[Meter:X]` in the first update (measures update
  before meters) gets the provisional layout of §1 ("Meter geometry before the first update"), not 0; so does a
  meter that names a meter below it (`X=([Target:X] - 4)` above `[Target]`), which is not placed yet when the first
  update reaches the reader.
- Log lines: a value that cannot be checked before its section variables have values is not reported at load — a
  MeterStyle name built from one (Enigma's Reader / Notes grabbers `StyleReaderGrabber[MeasureActive1]`, whose
  DynamicVariables=1 comes from a style; its Launchers' and Dock menu's `…Icon[MeasureProcess]`, which read "0" at
  load and "Running" / "Closed" once the Process measure has updated), a Calc `Formula` or an `IfCondition` that
  names a meter. They are checked at the first update, with the values resolved, and reported then if still wrong.
  Earlier builds logged spurious "MeterStyle … does not exist" warnings for them (8 per Reader / Notes skin).
- Judgment: Rainmeter presumably resolves them when the skin loads, before any measure has a value; the Mac resolves
  them at the first update, so a measure value is its first value (Simple Clean Greets shows "Good afternoon,
  <user>!" for `Postfix=,[MeasureUserName]!` with an `UpdateDivider=-1` SysInfo measure), not an empty string.
  Meter positions and sizes are the same either way for meters above the section. The value is never updated
  without DynamicVariables=1 (a `[MeasureCPU]` in a static Text stays at its first value).
- Why: the corpus evidence above; the load-time read has no measure values and no meter positions yet.
- Skin impact: layouts that place meters with `[Meter:X]` / `[Meter:W]` without DynamicVariables line up as on
  Windows; values meant to change still need DynamicVariables=1, as in Rainmeter.
- Status: emulated (resolution time: judgment call)

### Misspelled / legacy option names
- Windows (Rainmeter): not documented; skins known to work use `ValueReminder` for `ValueRemainder` on Roundline /
  Rotator (Enigma's Sidebar / Taskbar / World clocks, 21 uses; Elegant Watch) and their hands move.
- Mac (Deskset): `ValueReminder` is accepted wherever `ValueRemainder` is read (MeterStyles and `!SetOption` too);
  the documented spelling wins when both are set. The Image meter's deprecated `Path` (for ImagePath) works too.
- Why: other misspellings found in the corpus are not aliased because nothing shows that Rainmeter
  accepts them: `GrayScale` (one Enigma style; the manual spells Greyscale), `Substitue` (Nelamint Player).
- Skin impact: analog clocks written with the misspelling move their hands.
- Status: identical (by observation)

### Compatibility notes shown to users
- Windows (Rainmeter): errors and warnings go to the log (About → Log).
- Mac (Deskset): `skin.issues` ("Compatibility Notes" in the menu and Manage window) lists only things that work
  differently on the Mac: Windows-only measures and plugins (Windows DLLs no module provides), unsupported bangs,
  registry values that do not exist here, SysInfo types without a Mac answer, Histogram image options not supported,
  WebParser certificate flags. Mistakes in the skin that Rainmeter treats the same way are log lines only: a missing
  MeterStyle, an invalid Container, an unknown bang (not in the manual), a `Measure=` / `Meter=` type that does not
  exist, `Measure=Plugin` without `Plugin=`, a `SysInfoType` the manual does not list. Values that depend on
  section variables are checked only once those resolve (see "Section variables in options without
  DynamicVariables").
- Core-only contexts: plugins the Deskset app implements (NowPlaying, MediaKey, WiFiStatus, AudioLevel, Win7Audio,
  AppVolume, InputText, FrostedGlass, iTunes, WebNowPlaying, Chameleon, IsFullScreen, GetActiveTitle, SysColor) are
  registered by the app at startup, so users never see a note for them. Where DesksetCore runs without the app (the
  self-tests, tools), the note says `Plugin "NowPlaying" is provided by the Deskset app and is not available here`
  instead of calling them Windows plugins (`Skin.appProvidedMeasures`); in the `Measure=` form only for the
  documented measure types NowPlaying, MediaKey and WiFiStatus. A plugin name written as a measure type
  (`Measure=AudioLevel`, `Measure=InputText`) is not a Rainmeter measure type and the app registers these only as
  plugins: it is an invalid type in every context (a log line, no note), as on Windows. The app self-test checks that
  `Skin.appProvidedMeasures` is exactly the set of names the app registers.
- Transient notes: `Skin.removeIssue(_:)` takes a note back when it no longer applies (the app uses it for macOS
  permissions granted after the note was added, and RecycleManager for the Trash size once it can be read); a note
  removed and added again moves to the end of the list.
- Why: the notes tell users what to expect on a Mac; a skin's own mistakes are not a Mac difference.
- Skin impact: fewer, more relevant notes; authoring warnings are still in the log.
- Status: Mac-only UI

### Hex colors with a `0x` prefix
- Windows (Rainmeter): the manual (Option Types → Color, https://docs.rainmeter.net/manual/skins/option-types/#Color)
  only documents `RRGGBB[AA]` and `R,G,B[,A]`; how a `0x` prefix is read is not documented.
- Mac (Deskset): `0xRRGGBB` / `0xRRGGBBAA` (`0x` or `0X`) are accepted as hex colors. Evidence: EasyInfo writes every
  color as `0x0F0F2F` (before this, its background was the default gray and its text black on the Mac).
- Why: judgment call — skins in the wild write colors this way and evidently saw them work; C-style hex parsing
  accepts the prefix.
- Skin impact: such skins show their intended colors instead of the defaults.
- Status: emulated (judgment call; earlier builds rejected the prefix)

### Skin files (`.ini` / `.inc`, `@Include`)
- Windows (Rainmeter): section and key names are case-insensitive, `;` starts a comment line, "Rainmeter will ignore
  quotes around option values", a repeated section is "entirely ignored", `@Include` merges a file as if pasted, and
  relative paths are "relative to the current skin folder" (/manual/skins/, /manual/skins/include-files/).
- Mac (Deskset): the same. Judgment calls where the manual is silent: one pair of matching quotes, `"` or `'`, around a
  whole value is removed (`"""x"""` → `""x""`); a key repeated within one section of one file: the first wins; an
  `@Include` before any section is ignored (with a warning); a missing include file is also looked for next to the
  including file and case-insensitively; encodings: UTF-32 / UTF-8 / UTF-16 byte-order marks, BOM-less UTF-16, UTF-8,
  otherwise Windows-1252; an unterminated `[Name` line is a section header; include limits 30 levels, 500 files,
  32 MB per file. `!WriteKeyValue` writes a value with leading or trailing spaces in quotes (so it reads back
  unchanged) and turns line breaks in a value into spaces.
- Why: the manual does not describe these edge cases; the fallbacks only apply when a file would otherwise be missing.
- Skin impact: none for valid skins.
- Status: identical (+ leniencies)

### Variables (details)
- Windows (Rainmeter): `#Var#`, nested `[#Var]`, escapes `#*Var*#` / `[*Name*]`, character variables `[\x263A]` /
  `[\9731]` for "x0–xFFFE / 0–65536"; `[M:]` gives "up to ten decimal places" (/manual/variables/).
- Mac (Deskset): the same, plus: character variables accept any Unicode code point up to U+10FFFF (emoji) and an
  upper-case `X`; a variable's value is scanned again where it is used, so `!SetVariable V "[MeasureCPU]"` behaves as
  text substitution; `#Var#` is resolved before section variables (manual: normal variables take priority);
  `[M:%]` is clamped to 0–100, `[M:/N]` accepts any finite non-zero divisor, and numbers are rounded half away from
  zero (`[M:0]` of 2.5 = 3) with trailing zeros removed unless a decimal count is given; Windows environment
  variables (`%APPDATA%`) are not expanded.
- Why: judgment calls where the manual is silent; macOS draws every Unicode plane.
- Skin impact: none for valid skins.
- Status: identical (+ leniencies)

### Formulas
- Windows (Rainmeter): the operators and functions of /manual/formulas/; precedence is not documented; `.5` must be
  written `0.5`; operands of `&&` / `||` "must" be in parentheses; `?:` nests at most 30 deep.
- Mac (Deskset): C-like precedence, lowest to highest: `?:`, `||`, `&&`, `= <>`, `< > <= >=`, `|`, `^`, `&`, `+ -`,
  `* / %`, unary `- + ~`, `**` (right-associative, tighter than a unary minus on its left: `-2**2` = -4). Division
  or modulo by zero and non-finite results give 0; `%` is C `fmod` (`-7 % 3` = -1); bitwise operators work on whole
  numbers; `Round(x)` rounds half away from zero; `Min` / `Max` accept more than two arguments. Leniencies: `.5`,
  `5.`, exponents (`1e3`), `0b` / `0o` / `0x` prefixes (lower case) in every formula, `&&` / `||` without
  parentheses, `==` for `=`, no nesting limit. A plain number option reads its leading number (`12px` → 12).
- Why: judgment calls where the manual is silent; a formula must never crash or return NaN.
- Skin impact: none for valid formulas; formulas that Rainmeter rejects may work on the Mac.
- Status: identical (+ leniencies)

### Number formatting (NumOfDecimals, AutoScale, Scale, Percentual)
- Windows (Rainmeter): AutoScale `0`, `1`, `1k`, `2`, `2k` with units "k, M, G"; the history mentions a consistent
  space before the unit; Scale with a decimal point "will also display decimals".
- Mac (Deskset): units k, M, G, T (T the largest); `1m` / `1g` / `1t` / `2m` / `2g` / `2t` are accepted as an extension;
  the space is always added, even without a unit (Mnml Drives' `Text="%1 %"` with AutoScale=1 shows "96.2  %",
  Enigma's System percentages "81.6 %"; not checked against Windows); the unit is chosen from the unrounded value
  (1024 → "1.0 k"); Scale with a decimal point shows 1 decimal unless NumOfDecimals is set; Percentual is clamped to
  0–100; rounding follows printf (ties to even: 2.5 → "2"), "-0" prints as "0"; NumOfDecimals is limited to 0–30.
- Why: judgment calls where the manual is silent.
- Skin impact: an AutoScale value may differ from Windows by a space or a last-digit rounding.
- Status: emulated

### Time and Uptime formats
- Windows (Rainmeter): Time `Format` uses strftime codes with the `#` flag (/manual/measures/time/); the value is
  seconds since 1601; Uptime uses `%1`…`%4` with printf-style specs; FormatLocale / TimeStampLocale use Windows
  locale data.
- Mac (Deskset): the same codes. Judgments: `%r` is "10:55:03 PM" (upper case, like `%p`); `%Z` is the English zone
  name; unknown codes (`%Q`) are shown as written; an empty Format is `%H:%M:%S`; with Format set, the number value
  is the leading number of the text; TimeZone accepts fractional hours (5.5) and is clamped to ±18 h; TimeStamp
  parsing is lenient (fewer digits, any case, trailing text ignored); AddDaysToHours defaults to 1 as documented.
  Locale formats (`%c`, `%x`, `locale-date`) come from macOS (ICU) data and can differ from Windows' (e.g. a two-digit
  year in German `%c`).
- Why: judgment calls where the manual is silent; macOS locale data.
- Skin impact: localized dates may be spelled slightly differently.
- Status: emulated

### Actions, bangs and Substitute
- Windows (Rainmeter): `[!Bang arg "arg with spaces"]`, magic quotes `"""…"""`, legacy `!Rainmeter…` bang names
  (/manual/bangs/); Substitute pairs and RegExpSubstitute use PCRE (/manual/measures/general-options/substitute/).
- Mac (Deskset): the same syntax. Judgments: bang names are case-insensitive; a quote starts a quoted argument only at
  the beginning of a word; with three or more quotes in a row the last three close the argument; brackets inside
  quotes do not end the bang; text between bracketed bangs is ignored; `!Execute` nesting stops after 8 levels.
  Plain substitution is case-sensitive; `'a':'b'` (single quotes on both sides) is accepted although the manual says
  it fails; an empty pattern only replaces an empty value. Regular expressions are PCRE patterns translated to ICU:
  `(?U)`, lookarounds and named groups work; `(?|…)` renumbers groups, `\K` is dropped, conditionals become plain
  alternatives, backtracking verbs are dropped, recursion is not supported; `\w`, `\d` and `(?i)` are
  Unicode-aware; `.` and `$` also treat `\r` and U+2028 as line ends; each regex operation stops after 1 second of
  CPU time (at most 10 seconds of real time on a busy Mac).
- Why: ICU instead of PCRE; judgment calls where the manual is silent.
- Skin impact: common patterns (`(?siU)<tag>(.*)</tag>`) behave the same; exotic PCRE features may not match.
- Status: identical (common cases) / partial (exotic PCRE)

### Update interval and Counter
- Windows (Rainmeter): `Update` minimum 16 ms, -1 = once; the Calc `Counter` "only resets when the skin is unloaded
  and then loaded again - not when the skin is refreshed".
- Mac (Deskset): `Update` below 16 (including 0) is raised to 16; -1 updates once; Counter continues across a refresh.
- Why: as documented.
- Skin impact: none.
- Status: identical

---

## 4. Measures

### Measures that "were previously a plugin"
- Windows (Rainmeter): SysInfo, Process, WebParser, RecycleManager, MediaKey, NowPlaying and WiFiStatus pages each
  say the measure "was previously a plugin measure" and "still works with those forms": `Measure=Plugin` with
  `Plugin=Name`, `Name.dll` or `Plugins\Name.dll`.
- Mac (Deskset): those forms are the built-in measure (evidence: Simple Clean Greets and FluentDash11 use
  `Plugin=SysInfo`). Measures registered by other modules (Lua, bundled plugins) are found either way: a former
  plugin registered as `Plugin=` also answers `Measure=Name` and vice versa (RecycleManager by the core plugins;
  NowPlaying, MediaKey and WiFiStatus by the app). `Plugin=PowerPlugin` is the engine's battery measure. Other names
  in the plugin form are not built-in measures (`Plugin=Calc` is not a Calc measure).
- Why: as documented.
- Skin impact: old skins written with the plugin syntax work without a compatibility note.
- Status: identical (RecycleManager: plugins.md; NowPlaying, MediaKey, WiFiStatus: media-ui.md; where DesksetCore runs
  without the app, these three give the neutral "provided by the Deskset app" note of §3)

### CPU
- Windows (Rainmeter): 0–100; `Processor=0` all cores, N core N.
- Mac (Deskset): from `host_processor_info` (user + system + nice ticks). Cores are the Mac's logical cores (on
  Apple silicon: performance and efficiency cores, no hyper-threading). The app's very first sample is the average
  load since boot (there is no previous sample to measure an interval against); after that, the load between
  samples. The manual does not say what the first value is.
- Why: Mach host statistics are the macOS source of CPU load; a first value of 0 fixed too narrow a window for skins
  without DynamicWindowSize (see "cpu meter" in §2).
- Skin impact: per-core graphs show the Mac's core count; the first value is plausible rather than 0.
- Status: emulated

### Memory, PhysicalMemory, SwapMemory
- Windows (Rainmeter): Memory = physical + page file ("commit charge"), SwapMemory = page file, PhysicalMemory =
  RAM.
- Mac (Deskset): following the manual's definitions with macOS swap standing in for Pagefile.sys: PhysicalMemory =
  RAM (used = app + wired + compressed memory, Activity Monitor's "Memory Used"); SwapMemory = RAM + swap (used =
  RAM used + swap used); Memory = both added (total = 2 × RAM + swap). `Free=1` (undocumented, used by skins) gives
  total − used. MaxValue is automatic.
- Why: macOS has no page file of a fixed size; swap files grow on demand.
- Skin impact: Mac users may expect SwapMemory to be swap only; Memory / SwapMemory percentages have no Activity
  Monitor counterpart.
- Status: emulated

### NetIn / NetOut / NetTotal
- Windows (Rainmeter): bytes per second; `Interface` = Best (default), 0 = all, N or an adapter name.
- Mac (Deskset): Best = the active interface (wired preferred over Wi-Fi); 0 = all active interfaces except VPN
  tunnels, AWDL / low-latency WLAN, bridges and similar virtual ones (so traffic is not counted twice); a Windows
  adapter name or alias (`Wi-Fi`, `Ethernet`, `Intel(R) …`) or an index that does not exist falls back to Best
  (logged once). Rates use the real time between samples; `Cumulative=1` counts since boot (no statistics are kept
  across restarts, `!ResetStats` is not handled).
- Why: macOS interface names (en0, en1…) differ from Windows adapter names; virtual interfaces would double-count.
- Skin impact: skins that name a Windows adapter measure the active Mac interface instead.
- Status: emulated

### FreeDiskSpace
- Windows (Rainmeter): `Drive=C:`; Total, Label, Type, IgnoreRemovable.
- Mac (Deskset): every drive letter (`C:`, `D:`, `C:\`) is the startup volume `/` (so D:, E: repeat it); a bare name
  (`Data`) means `/Volumes/Data`; absolute paths work. On APFS the numbers are the container's (used = everything
  on the disk, as Finder reports). Type: Fixed / Removable / Network / CDRom / Ram from the volume's properties
  (USB hard disks count as Fixed).
- Why: macOS has no drive letters.
- Skin impact: several drive letters show the same volume; name a volume (`Drive=/Volumes/Backup`) for others.
- Status: emulated

### SysInfo
- Windows (Rainmeter): SysInfoType values for OS, user, network adapters, monitors, time zone… (/manual/measures/sysinfo/).
- Mac (Deskset): monitor values (NUM_MONITORS, SCREEN_*, WORK_AREA*, VIRTUAL_SCREEN_*) in points, monitor 1 = the
  primary screen; SCREEN_SIZE / WORK_AREA formatted "1920 x 1080"; TIMEZONE_* with Windows sign conventions
  (TIMEZONE_ISDST = -1 for zones without DST); OS_BITS 64; OS_VERSION / OS_PRODUCT_NAME name macOS; USER_NAME,
  COMPUTER_NAME, IP / MAC / adapter types from the app; DOMAIN_WORKGROUP is the SMB workgroup ("WORKGROUP" by
  default). Documented types without a Mac answer (USER_SID, ADAPTER_GUID) give 0 / "" and a compatibility note, and
  a String meter showing only such a value keeps one line of height (see §2); a type the manual does not list (a
  typo) gives 0 / "" and a log line.
- Why: some types are Windows concepts (domain / workgroup, adapter aliases of Windows).
- Skin impact: monitor sizes are in points; network adapter types need a Mac interface (see NetIn).
- Status: emulated / partial

### Registry
- Windows (Rainmeter): reads any registry value (REG_SZ → string, numeric strings also set the number; DWORD /
  QWORD → numbers; OutputType SubKeyList / ValueList).
- Mac (Deskset): the registry does not exist. The values skins commonly read for machine facts are answered with
  macOS equivalents (keys and names case-insensitive; `WOW6432Node` and `ControlSet00N` read like the current ones):
  - `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`: ProductName (as SysInfo OS_PRODUCT_NAME, e.g. "macOS
    Tahoe"), CurrentVersion ("26.5"), CurrentMajorVersionNumber / CurrentMinorVersionNumber (numbers),
    CurrentBuild / CurrentBuildNumber / BuildLab(Ex) (macOS build, e.g. "25F71"), DisplayVersion / ReleaseId
    ("26.5.1"), UBR (patch number), RegisteredOwner (full user name), RegisteredOrganization (""),
    InstallationType ("Client"); `…\WinSat` PrimaryAdapterString = the chip name on Apple silicon (its GPU is part
    of the chip), the graphics processor's name on an Intel Mac (from the I/O Registry; a discrete AMD / NVIDIA GPU
    before the integrated Intel one).
  - `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\N` (N < number of cores): ProcessorNameString (CPU brand,
    e.g. "Apple M4 Pro"), ~MHz (0 when unknown, as on Apple silicon), VendorIdentifier, Identifier; SubKeyList of
    CentralProcessor lists the cores.
  - `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` (the system environment variables):
    NUMBER_OF_PROCESSORS (logical cores, a string like "12" whose number is also set), PROCESSOR_ARCHITECTURE
    (ARM64 / AMD64), PROCESSOR_IDENTIFIER (the CPU brand string; Windows has "Intel64 Family 6 Model …");
    `…\Control\ComputerName\(Active)ComputerName` ComputerName. The other variables of that key (OS, ComSpec,
    Path, TEMP, windir, PROCESSOR_LEVEL / _REVISION…) name Windows things and are not emulated.
  - `HKCU\Volatile Environment` USERNAME, USERPROFILE; `HKCU\…\Explorer\Shell Folders` / `User Shell Folders`
    Desktop, Personal, My Music, My Pictures, My Video, Downloads → the folders in the home directory.
  - `HKCU\Control Panel\Desktop` Wallpaper: the path of the current desktop picture of the primary screen (the one
    with the menu bar; "" when the desktop shows no picture file), read again at every update of the measure because
    it changes while the skin runs (the other values are read once). The engine asks its data source
    (`SystemDataSource.desktopPicturePath()`); where the data source cannot tell, the value is not emulated (0 / ""
    and a compatibility note). The app answers it (and `--render` too) from `NSWorkspace.desktopImageURL(for:)`,
    looked at every 2 seconds at most. When the desktop picture is a folder of rotating pictures, macOS does not say
    which of them is showing: the value is the folder's first picture by name (the picture Chameleon `Type=Desktop`
    samples too), or "" when the folder holds no picture; the folder is listed on a background queue (never while
    the skins update), so the value is "" until that first look has finished — the measure shows the picture at
    its first update after that, so one with a large `UpdateDivider` (Enigma's Layout options: 30) shows it that
    much later — and then follows the folder every 30 seconds.
  Everything else reads 0 / "" and is listed once as a compatibility note. Not emulated on purpose: video memory
  (`…\Control\Class\{4d36e968-…}\000N` HardwareInformation.qwMemorySize) — Apple silicon GPUs have no memory of
  their own (they share the unified memory), so no number would mean the same thing.
  Keys the corpus reads: CurrentVersion (HMNmeter2's Network Meter, to tell Windows 7 from 8+: "26.5" counts as
  the newest), WinSat PrimaryAdapterString (FluentDash11 GPU and SYSINFO), NUMBER_OF_PROCESSORS (Enigma Process:
  `Scale=([MeasureCores]*100000*#ProcessInterval#)` turns AdvancedCPU's CPU time into percent; its process list
  shows plausible percentages), Wallpaper (Enigma Options → Layout: a thumbnail of the wallpaper), qwMemorySize
  (FluentDash11 GPU: total VRAM, shown as 0 GB).
- Why: skins show the Windows version or the CPU / GPU name, scale per-process CPU time by the core count, or show
  the wallpaper; a Mac answer is more useful than an empty row.
- Skin impact: version comparisons meant for Windows builds (e.g. `CurrentBuild >= 22000` for Windows 11) see a
  macOS build string such as "25F71", which is not a number (its number value is 0). Skins reading video memory
  show 0. With rotating desktop pictures a wallpaper thumbnail may show another picture of the folder than the one
  on screen; a dynamic or aerial desktop shows whatever file macOS names for it (a still picture) or nothing.
- Status: emulated (a fixed set of values)

### Windows-only measures and plugins
- Windows (Rainmeter): built-in Windows measures and third-party plugin DLLs.
- Mac (Deskset): many of them are reimplemented by other modules, which the engine asks first (`MeasureRegistry`):
  plugins.md (CoreTemp, SpeedFan, AdvancedCPU, UsageMonitor, PerfMon, RecycleManager, ResMon, WindowMessage, …),
  audio.md (AudioLevel, Win7AudioPlugin), media-ui.md (NowPlaying, iTunes, MediaKey, WiFiStatus, InputText,
  FrostedGlass, …), lua.md (`Measure=Script`). Whatever no module provides — any other Windows DLL — gives 0 / ""
  (and `!CommandMeasure` does nothing) with the note `Plugin "X" is a Windows plugin and is not supported`, and
  never crashes the skin. String meters showing only such a value keep one line of height (see §2). The plugins the
  app provides always exist in the app; only where DesksetCore runs without it do they fall back, with a neutral
  note (§3, "Compatibility notes shown to users").
- Why: they read Windows-only APIs or are Windows DLLs.
- Skin impact: the parts of a skin that show an unprovided plugin stay empty.
- Status: not supported (engine fallback; see the other files for what is reimplemented)

### Other measure judgment calls
- Windows (Rainmeter): the manual does not settle these details.
- Mac (Deskset):
- Range tracking (Measures → Percentage): Calc, Net (without InSpeed / OutSpeed), WebParser, Script (lua.md) and
  the core plugins whose values change (plugins.md) without MinValue / MaxValue widen their range from 0…1 by the
  values seen; `MaxValue=100` alone gives 0…100.
- Update order of one measure (not documented): compute → range → average → invert → IfConditions →
  IfAbove/IfBelow/IfEqual → IfMatch → OnChangeAction → OnUpdateAction. IfAbove/IfBelow re-arm once the value is no
  longer above/below; IfEqual compares rounded values. IfAbove/Below/EqualAction without its Value option never
  fire (no default documented).
- Loop: always moves from StartValue towards EndValue by |Increment|.
- Time: numbers are local wall-clock seconds since 1601 in whole seconds.
- PowerPlugin: Percent 100 and ACLine 1 on Macs without a battery; Lifetime -1 / "Unknown" while unknown.
- Process: `.exe` is dropped from ProcessName (`Firefox.exe` → Firefox); Mac process names often differ from the
  Windows executable names.
- Why: judgment calls where the manual is silent.
- Skin impact: edge cases only (a constant Calc bound to a Bar needs MaxValue, as in Rainmeter).
- Status: emulated

---

## 5. Meters and drawing

### Bound measures (`MeasureName`, `MeasureName2`…)
- Windows (Rainmeter): `%1`, `%2`… in Text / ImageName are the values of MeasureName, MeasureName2…
- Mac (Deskset): `%N` and single-measure meters (Bar, Roundline, Rotator, Bitmap, Image without `%N`) use the measure
  of `MeasureNameN` exactly — a `MeasureName` that names no measure leaves slot 1 empty instead of moving
  `MeasureName2` into it. `%N` is replaced in one pass (a value containing "%2" is not substituted again).
- Why: as documented; the earlier "first found measure" binding was a bug.
- Skin impact: none.
- Status: identical

### Image files
- Windows (Rainmeter): "If no file extension is included, .png is assumed." Supported: png, jpg, bmp, gif, tif, webp, ico.
- Mac (Deskset): `.png` is added when the name has no extension and no file of exactly that name exists (an existing
  extensionless file is used as is); a name with a non-image extension (a measure value like "12.5") also gets
  `.png` unless the exact file exists. Extensions: png jpg jpeg jpe bmp dib gif tif tiff webp ico heic. Files are
  checked against the disk on every use, so edited images show up without DynamicVariables. Images larger than
  8192 px per side are downsampled.
- Why: leniencies that cannot break a valid skin; the size cap bounds memory.
- Skin impact: none for normal images.
- Status: identical (+ leniencies)

### Image options
- Windows (Rainmeter): General Image Options (/manual/meters/general-options/image-options/); order of operations
  and colour maths not documented.
- Mac (Deskset): ImageFlip before ImageRotate (clockwise); crop and rotate after EXIF orientation; areas of an
  ImageCrop outside the image are transparent; ImageTint multiplies (white = unchanged; Greyscale + tint recolors);
  Greyscale uses Rec. 601 weights (the ColorMatrix guide's example uses 0.33/0.59/0.11); ColorMatrix replaces
  ImageTint/ImageAlpha, Greyscale still applies first; missing ColorMatrix rows / values keep the identity.
  PreserveAspectRatio with only one of W/H follows the aspect ratio unless `PreserveAspectRatio=0` is written.
  Masks keep the more transparent alpha of image and mask. `UseExifOrientation=1` is honoured for Image, Bar, Bitmap,
  Button, Rotator and Background (default 0: the pixels as stored). Histogram's PrimaryImageRotate and ColorMatrix
  options are not supported (compatibility note).
- Why: judgment calls where the manual is silent; CoreGraphics rotation and scaling.
- Skin impact: tinted / greyscaled images may differ slightly in tone.
- Status: emulated / partial

### Bar, Bitmap, Button
- Windows (Rainmeter): /manual/meters/bar/, …/bitmap/, …/button/ and Tips → Button Images.
- Mac (Deskset): Bar fill lengths are whole pixels; BarImage is drawn at its own size and BarBorder ends are always
  drawn. Bitmap / Button strips are horizontal when the image is wider than tall; BitmapZeroFrame and transitions
  as documented, BitmapAlign like StringAlign. Button: ButtonCommand ignores transparent pixels; a Button with its
  own LeftMouseUpAction etc. still runs it — an action removed with `!ClearMouseAction` no longer counts, a disabled
  one still catches the event. ImageFlip flips each frame in place.
- Why: judgment calls where the manual is silent.
- Skin impact: none expected.
- Status: emulated

### Roundline and Rotator
- Windows (Rainmeter): /manual/meters/roundline/, …/rotator/; several defaults and the modulo details are not
  documented.
- Mac (Deskset): undocumented defaults: StartAngle 0, RotationAngle 2π, LineStart 0, LineLength 0. ValueRemainder
  uses a floating-point modulo (hands move smoothly), negative values wrap into 0…R, MinValue/MaxValue are ignored
  in that mode. No bound measure = 100 % for both meters. Solid with ControlStart/ControlLength draws a sector with
  both radii at the current percentage; Solid with ControlAngle=0 fills the whole circle. Rotator images are drawn at
  their pixel size, not clipped to W×H; rotated images are always smoothed.
- Why: the documented clock example only works this way; the rest are judgment calls.
- Skin impact: clock hands move smoothly between seconds when the value is fractional.
- Status: emulated

### Line and Histogram
- Windows (Rainmeter): /manual/meters/line/, …/histogram/.
- Mac (Deskset): GraphOrientation=Horizontal is the vertical graph turned 90° clockwise; history not yet filled reads
  as 0 (a flat line across the graph at first); without AutoScale the range is the lowest MinValue to the highest
  MaxValue (Line) or each measure's own range (Histogram); with AutoScale one range from the recorded samples;
  HorizontalLines draws 3 lines at the quarters; LineColor defaults to white; hidden meters keep sampling and
  `!UpdateMeter` adds a sample.
- Why: judgment calls where the manual is silent.
- Skin impact: a new graph starts flat instead of growing from one edge.
- Status: emulated

### Shape
- Windows (Rainmeter): /manual/meters/shape/ (Direct2D geometry).
- Mac (Deskset): W/H from the stroked bounds rounded to whole pixels (matches the manual's screenshots); Miter joins
  past the limit are beveled; dashes restart per figure; shapes are always anti-aliased; `StrokeType` and a Combine
  `Consume` flag are accepted extensions. An empty required parameter counts as 0 — FluentDash11 draws its buttons
  with `Rectangle ,,100,50,8` and the author's screenshot shows them at the meter's X/Y (`Rectangle ,,,` or a missing
  parameter is still an error). Combined shapes' bounds are an upper bound.
- Why: CoreGraphics instead of Direct2D; the empty-parameter rule follows the author's screenshot.
- Skin impact: very sharp mitered corners and combined shapes can differ by a pixel.
- Status: emulated

### Mouse hit areas
- Windows (Rainmeter): fully transparent pixels of a skin are not clickable.
- Mac (Deskset): inside the skin, meter rectangles (Shape: its solid parts; Button: its opaque pixels) catch the
  mouse; clicks on fully transparent pixels of the window are left to macOS, which passes them to what is behind.
- Why: AppKit hit-tests borderless transparent windows by pixel alpha.
- Skin impact: a meter with an invisible SolidColor=0,0,0,1 background catches clicks, as on Windows.
- Status: identical

---

## 6. Mouse, bangs and actions

### !Delay
- Windows (Rainmeter): "the skin will be unresponsive" during the delay (the skin is blocked).
- Mac (Deskset): the rest of the action runs later on the main queue; the skin keeps updating; a refresh or unload
  cancels the pending part.
- Why: blocking the main thread would freeze every skin and the app.
- Skin impact: an update can run in the middle of a delayed action.
- Status: emulated

### OnFocusAction, OnUnfocusAction, OnWakeAction
- Windows (Rainmeter): run "at the very end of the update cycle".
- Mac (Deskset): focus actions run when the focus changes (an `Update=-1` skin never reaches another update);
  OnWakeAction runs at the end of the first update after the Mac wakes (right away for `Update=-1`).
- Why: see above.
- Skin impact: none expected.
- Status: emulated

### Formulas in bangs
- Windows (Rainmeter): "Measures in a (formula) … used in any Bang do not require DynamicVariables" (Dynamic cheat
  sheet).
- Mac (Deskset): a `!SetOption` value that is one parenthesized formula naming measures is evaluated when the bang
  runs; Calc `Formula` / `IfCondition` values set by `!SetOption` are stored as written (so they keep following
  their measures); `!SetVariable` / `!WriteKeyValue` formula results keep up to 10 decimals, trailing zeros removed.
- Why: judgment on the details.
- Skin impact: none expected.
- Status: identical

### Keyboard modifiers and scrolling
- Windows (Rainmeter): Ctrl overrides Draggable / SnapEdges while dragging; mouse wheel actions.
- Mac (Deskset): ⌘ replaces Ctrl (Ctrl-click opens the context menu on a Mac); scroll actions follow the physical
  direction (natural scrolling undone); a trackpad fires one scroll action per 24 points of movement.
- Why: macOS conventions.
- Skin impact: none.
- Status: emulated

### Tooltips and cursor
- Windows (Rainmeter): tooltips substitute `%N` with the String-meter format forced to AutoScale=1, 0 decimals;
  MouseActionCursor shows a hand over mouse actions.
- Mac (Deskset): the same forced format for every meter type; hover actions (MouseOver/MouseLeave) do not show the
  hand.
- Why: judgment where the manual is silent.
- Skin impact: none expected.
- Status: identical

### Bangs that are not supported
- Windows (Rainmeter): every bang in /manual/bangs/.
- Mac (Deskset): a documented bang the app cannot perform is a compatibility note; a name that is not a Rainmeter bang
  (a typo) is only logged.
- Why: see §3.
- Skin impact: none.
- Status: partial (see the app's notes for the individual bangs)

### Runaway actions
- Windows (Rainmeter): no documented limit.
- Mac (Deskset): actions that keep triggering each other stop after 20 000 steps per update / top-level action or 16
  levels of nesting (logged), and `!Update` inside an update is ignored, instead of hanging the app.
- Why: a skin must never hang the app.
- Skin impact: only skins that would hang.
- Status: Mac-only safety limit

---

## 7. Limits

### Safety bounds on sizes and counts
- Windows (Rainmeter): the manual gives no limits.
- Mac (Deskset): X, Y, W, H and meter frames within ±1 000 000 points; window sides 1…16 384 points; String meter text
  cut at 32 768 UTF-16 units, at most 4 096 inline ranges and 5 000 lines, FontSize 0…1000; images decoded at most
  8192 px per side, ImageCrop / canvases ≤ 32 768 px, colour-matrix bitmaps over 16 M pixels drawn without the
  transform; at most 500 distinct log-once messages and compatibility notes per skin and 256 pending `!Delay`s.
- Why: hostile or broken formulas must not exhaust memory or crash the app.
- Skin impact: none for real skins.
- Status: Mac-only safety limit

---

## 8. Known differences not fixed in this round

- EasyInfo: its "Digital-7 Mono" font is not in the package, so the LED digits use Arial (same on a Windows PC
  without that font). (Its `0x`-prefixed colors work now, see §3.)
- PogPack 1.3 (legacy package layout `PogPack 1.3\Skins\PogPack\…`): `@Include=#SKINSPATH#\PogPack\…` only
  resolves once the package is installed so that `PogPack` is a root config; rendered straight from the extracted
  folder its variables (fonts, sizes) are undefined. Installer's business, not the engine's.
- FluentDash11 Network: `SysInfoData=#Adapter0#` names a variable the skin never defines; on the Mac the adapter
  rows are empty and the rows below them overlap (a SysInfo value that is empty is not "unavailable data").
- FluentDash11 CPU / GPU: temperatures, clocks and fan speeds come from CoreTemp (0 until sensor support, see
  plugins.md) and from the third-party MSI Afterburner DLL (not provided: empty rows that keep their height, §2);
  total VRAM reads 0 (Registry, §4). The FrostedGlass blur is media-ui.md's.
- Lua-driven layouts (Enigma's Taskbar skin widths, calendars, notes, readers) run their scripts now (lua.md); their
  first update sees provisional meter geometry (§1).
