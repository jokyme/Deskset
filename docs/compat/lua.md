# Lua scripting (Measure=Script, inline Lua)

Sources: the manual pages [Lua Scripting](https://docs.rainmeter.net/manual/lua-scripting/),
[Inline Lua](https://docs.rainmeter.net/manual/lua-scripting/inline-lua/),
[Script measure](https://docs.rainmeter.net/manual/measures/script/),
[Unicode in Rainmeter](https://docs.rainmeter.net/tips/unicode-in-rainmeter/) (Lua section) and the Lua notes in the
[version history](https://docs.rainmeter.net/history/). Implementation: `Sources/DesksetCore/Engine/Lua/`
(`ScriptMeasure`, `LuaState`, `LuaPrelude`, `InlineLua`, `LuaSupport`) and the C shims `Sources/CLua/deskset_lua.c`
and `Sources/CLua/deskset_lstrlib.c`. Lua 5.1.5's own source files are embedded unmodified; the shims replace or
remove a few library functions in each script's state at run time (`deskset_lstrlib.c` is a modified copy of the
pattern-matching part of `lstrlib.c`, MIT; details in `Sources/CLua/README.md`). Tests:
`swift run DesksetSelfTest Lua`. Fixtures: `TestSkins/Lua/` (LuaShowcase, LuaInline, LuaErrors).

Verified on third-party skins (local testing only): Enigma's Reader (RSS parsing in Lua, WebParser → Lua →
`!SetVariable` → meters), Notes, Calendar, Options and HMNmeter2's FixedPrecisionFormat now render their Lua-driven
content; before, those areas stayed empty.

## Script measure and the Lua environment

### Lua version and one state per Script measure
- Windows (Rainmeter): Lua 5.1 with its standard libraries; "each script measure creates a separate instance of its
  script … Global variables are not shared between instances" (Lua Scripting, Script Measure).
- Mac (Deskset): Lua 5.1.5 (the reference implementation; its sources are unmodified, and the library functions
  listed below are removed or replaced at run time). Every Script measure gets its own `lua_State`; it is created
  when the skin loads and closed when the measure is released (skin refresh / unload).
- Why: same language version, so scripts behave the same.
- Skin impact: none.
- Status: identical

### Available libraries and removed functions
- Windows (Rainmeter): the Lua 5.1 standard libraries, except "the require, os.exit, os.setlocale, io.popen, and
  collectgarbage functions" and "external compiled libraries" (Lua Scripting, Restrictions). The history notes say
  debug, setfenv, getfenv and coroutine are available.
- Mac (Deskset): base, coroutine, table, string, math, io, os and debug are opened. Removed: `require`, `module` and
  the whole `package` library (never opened), `os.exit`, `os.setlocale`, `io.popen`, `collectgarbage` — as in the
  manual — plus `debug.sethook` (it would remove the time limit), `newproxy`, `debug.getmetatable`,
  `debug.setmetatable` and `debug.getregistry`, and `getmetatable(file)` returns `false`. File handles keep their
  methods (`f:read()`…) in a table of their own: `io.stdout.__index` and `io.stdout.__gc` are nil (in stock Lua 5.1
  they return the handles' metatable and its close function).
- Why: Lua 5.1 runs `__gc` metamethods with debug hooks disabled, so an endless loop inside one could never be
  stopped and would freeze the app. The removed functions and the separate method table close every way a script
  could attach Lua code to garbage collection (userdata from `newproxy`, or the shared metatable of file handles —
  which `io.stdout.__index` handed out even with `getmetatable` hidden). Judgment call.
- Skin impact: scripts that use these (rare, advanced) get "attempt to call a nil value"; the error is logged.
- Status: partial

### Functions restricted for memory safety (debug, loadstring / load, patterns)
- Windows (Rainmeter): the standard Lua 5.1 functions. In stock Lua 5.1 several of them trust the script completely:
  `debug.setfenv` / `debug.getfenv` reach the environments the io library reads without checks,
  `debug.setlocal` can change the stack slots of a running C function and the VM's hidden loop variables,
  `loadstring` / `load` accept precompiled bytecode (which Lua 5.1 does not verify soundly), and the pattern matcher
  recurses once per pattern item without a limit. A script can use each of these to crash the host process.
- Mac (Deskset): `debug.getfenv` returns the environment of Lua functions and threads (nil for C functions,
  userdata and other values); `debug.setfenv` accepts only Lua functions and threads (anything else is a "bad
  argument" error). `debug.setlocal` changes named local variables of Lua functions (also in another coroutine); for
  C functions and hidden locals (`(for index)`, `(*temporary)`) it changes nothing and returns nil, like for a
  missing local. `loadstring`, `load`, `dofile`, `loadfile`, ScriptFile and `!CommandMeasure` load text chunks only;
  a chunk starting with the bytecode signature (ESC `Lua`) gives "binary (precompiled) chunks are not supported"
  (`loadstring` / `load` return nil and that message, as for any load error). `string.find`, `string.match`,
  `string.gmatch`, `string.gsub` (and the old alias `string.gfind`) are Lua 5.1.5's own code with two additions: a
  recursion limit of 200 pattern levels ("pattern too complex", the limit Lua 5.2 and later have) and the time /
  instruction budget of the running call (see "Runaway scripts and memory"). Their results are otherwise identical
  (checked against stock Lua 5.1.5 on a set of 50 patterns).
- Why: a skin downloaded from the internet must never crash the app (or run native code in it). Judgment call; none
  of the corpus scripts use these functions in the affected ways.
- Skin impact: none for ordinary scripts. Scripts shipped as precompiled bytecode do not run (they would not survive
  the text decoding of ScriptFile either). A pattern with more than about 200 nested items (`string.rep('a?', 300)`)
  raises "pattern too complex" instead of crashing.
- Status: partial

### ScriptFile
- Windows (Rainmeter): path of the .lua file; "may now be a relative or fully described path" (history), relative to
  the skin folder like other file options; `#@#` etc. may be used.
- Mac (Deskset): same; `\` separators are converted, surrounding quotes removed, a file whose name differs only in
  case is found (skins written on case-insensitive Windows). Files that are not regular files or larger than 16 MB
  are not read. A missing file adds a compatibility issue ("Script file … not found") and logs an error; the measure
  then has the values 0 / "".
- Why: Windows paths and case-insensitive names are common in skins.
- Skin impact: none.
- Status: identical

### Script file encoding
- Windows (Rainmeter): the Unicode tips page says a .lua file must be UTF-16 to use Unicode, and "NEVER encode a .lua
  script file in UTF-8. The Rainmeter implementation of Lua will not be able to properly read it." ANSI files work
  for plain text.
- Mac (Deskset): the file is decoded like .ini files (UTF-8 with or without BOM, UTF-16 LE/BE with or without BOM,
  UTF-32 with BOM, otherwise the ANSI code page) and handed to Lua as UTF-8. A first line starting with `#` is
  ignored (like `luaL_loadfile`).
- Why: Lua sees text as UTF-8 in both cases (the tips page: Lua "internally views all text as UTF-8"); accepting UTF-8
  files is a leniency.
- Skin impact: UTF-8 scripts that show mojibake on Windows show the intended text on Mac.
- Status: emulated

### Text exchanged with the skin
- Windows (Rainmeter): strings passed between Lua and the skin are UTF-8 on the Lua side.
- Mac (Deskset): same. A Lua string that is not valid UTF-8 (e.g. bytes read from an ANSI data file with `io.read`)
  is shown as Windows-1252 instead of replacement characters. Judgment call.
- Skin impact: ANSI data files read by scripts show accented Latin characters correctly.
- Status: identical

### Main chunk and Initialize()
- Windows (Rainmeter): Initialize "is called one time … when the skin is activated or refreshed. This happens even if
  the script measure is disabled"; the inline Lua page adds that the global scope runs "during the initialization
  phase of the skin" and Initialize "will only be executed during the first update cycle of the skin". "If the script
  file is changed by a !SetOption bang, the new script's Initialize function is called as well."
- Mac (Deskset): the main chunk runs when the skin loads (so globals are there for inline Lua resolved while the skin
  loads, in DynamicVariables options). Initialize runs at the Script measure's turn in the first update (even when
  the measure is disabled, paused or has a negative UpdateDivider), or earlier when a `!CommandMeasure` reaches the
  script first (e.g. from the IfTrueAction of a measure above the Script measure). A ScriptFile changed by
  `!SetOption` loads the new file and runs its Initialize at once. Bangs issued by the main chunk (or by inline Lua
  while the skin loads) run right after Initialize.
- Why: the manual does not say where in the first update Initialize runs; running it before any command guarantees
  commands see initialized globals. Judgment call.
- Skin impact: none for skins that work on Windows.
- Status: identical

### Update() and the measure values
- Windows (Rainmeter): `return` / no return → 0 and ''; `return 99` or `'99'` → 99 and '99'; `return 'Text'` → 0 and
  'Text'; `return 99, 'Text'` in any order → both. The measure "responds normally to the Disabled option, the
  UpdateDivider option, and all measure bangs". History: the value "is … reset when an error occurs", and
  "AutoScale/Scale/Percentual/NumOfDecimals" apply to Script measures bound to meters.
- Mac (Deskset): same. A returned number has no separate string: String meters format it with NumOfDecimals /
  AutoScale / Scale / Percentual, and `[Script]` shows it with the engine's plain number format (up to 5 decimals,
  e.g. 0.33333) rather than Lua's `%.14g`. `true` / `false` count as 1 / 0; tables, functions and nil are ignored
  (only the first two return values are looked at). A runtime error in Update resets the values to 0 and "".
  Before the first update the string value is "" (manual: initial values 0 and "").
- Why: the history note on NumOfDecimals implies the number is formatted by the meter; booleans follow the inline Lua
  rule "true will be 1 and false will be 0". Judgment calls where noted.
- Skin impact: none expected.
- Status: identical

### MinValue / MaxValue of a Script measure
- Windows (Rainmeter): Measures → Percentage: measures that cannot know their range (Net, Calc, WebParser, …) use the
  smallest and largest values seen since the skin was loaded.
- Mac (Deskset): Script measures are treated as such measures unless MinValue / MaxValue are set (the range starts as
  0…1 and widens with the values seen, as for Calc).
- Why: a script cannot declare its range; the manual's list is given as examples. Judgment call.
- Skin impact: a Bar bound to a script without MaxValue fills relative to the largest value seen.
- Status: emulated

### Deprecated API: PROPERTIES, GetStringValue(), GetValue(), tolua.cast, SetText
- Windows (Rainmeter): deprecated but "still supported": the `PROPERTIES` table, `MyMeter:SetText()`, a global
  `GetStringValue()` function (history: also `GetValue()` and `tolua.cast()`).
- Mac (Deskset): `PROPERTIES` keys are filled from the measure's options after the main chunk (a number default reads
  the option as a number/formula); when `Update()` returns nothing, global `GetValue()` / `GetStringValue()`
  functions supply the number / string; `tolua.cast(x, type)` returns `x`; `Meter:SetText(t)` works like
  `!SetOption Meter Text t`.
- Why: the exact old behaviour is not documented; this keeps old scripts working. Judgment call.
- Skin impact: none expected.
- Status: emulated

## SKIN, SELF, Measure and Meter objects

### SKIN:Bang()
- Windows (Rainmeter): "Executes a bang. The bang will be executed by Rainmeter when control is returned from the
  script. Each bang parameter is a separate parameter in the function." "The !Delay bang … is not supported in Lua."
  Skins also pass whole action strings (`SKIN:Bang('[!A][!B]')`, `SKIN:Bang('!Refresh')`, `SKIN:Bang('"https://…"')`).
- Mac (Deskset): bangs are queued and run in order after the outermost Lua call of that script returns (after
  `Update()`'s values are set). Separate parameters stay whole (spaces, quotes and brackets included) and are resolved
  like action arguments when they run (`#Var#`, `[Measure]`, formulas for `!SetVariable`); numbers use Lua's number
  format, booleans become 1 / 0, nil becomes "". The bang name may omit `!`. A single string is run as an action; a
  single string that is neither a bang nor bracketed (`'"https://…"'`, `'notepad'`) is run as `["…"]`. `!Delay` given
  as a separate bang has no effect; inside an action string it delays the rest of that string. At most 10 000 bangs
  and 32 MB of bang text may be queued by one call (more are dropped and logged once). When a queued bang runs the
  same script again (`!CommandMeasure`), the bangs that call queues run after the ones already waiting (first in,
  first out).
- Why: the manual's timing rule; the rest keeps real scripts working. The `!Delay` difference is a judgment call.
- Skin impact: code that reads a value right after setting it with a bang sees the old value, as on Windows.
- Status: identical

### SKIN:GetVariable(), SKIN:MakePathAbsolute() and paths
- Windows (Rainmeter): GetVariable returns the current value or the default / nil; MakePathAbsolute makes a path
  relative to the skin folder absolute. Paths are Windows paths (`C:\…\Skin\`), and scripts split them with patterns
  such as `path:match('([^\\]-)%.([^%.]+)$')`.
- Mac (Deskset): same values, but paths handed to scripts — MakePathAbsolute results and the built-in folder variables
  `@`, `CURRENTPATH`, `ROOTCONFIGPATH`, `SKINSPATH`, `SETTINGSPATH`, `PROGRAMPATH`, `ADDONSPATH`, `PLUGINSPATH` — use
  `\` separators (`\Users\me\Library\…\Skin\`). `SKIN:ReplaceVariables()` gives the same form for `#@#`,
  `#CURRENTPATH#` and the other folder variables written as `#NAME#` (so both ways of reading a folder agree); the
  nesting form `[#@]` and option values read with `GetOption` keep `/`. Every path a script gives back (io, dofile,
  loadfile, os.remove, os.rename, bangs, options) accepts either separator. `GetVariable('CURRENTSECTION')` is the
  Script measure's name.
- Why: path-splitting patterns written for Windows (e.g. a notes skin that shows the file name of a
  MakePathAbsolute result) then work unchanged. Judgment call.
- Skin impact: a path a script shows in a meter uses backslashes, as on Windows. Scripts written for Deskset should not
  assume `/`.
- Status: emulated

### SKIN:GetX / GetY / GetW / GetH, MoveWindow, FadeWindow
- Windows (Rainmeter): the skin window's position and size; MoveWindow moves it; FadeWindow(from, to) fades the
  opacity at the speed of FadeDuration.
- Mac (Deskset): GetX / GetY are the window's top-left corner in points, measured from the top-left of the primary
  screen (the same coordinates as `!Move`); GetW / GetH are the skin size in points. MoveWindow runs `!Move X Y`
  (integers). FadeWindow(from, to) (both clamped to 0 … 255) is queued in order with the script's `SKIN:Bang()` calls;
  in the app the window is set to `from` and animated to `to` over FadeDuration, and the value is **not** saved: it
  lasts until the skin is refreshed or its AlphaValue is set again (`!SetTransparency`, the Transparency menu, the
  Manage window) — see `app.md`, "Lua SKIN:FadeWindow". Hosts without windows (`--render`, the engine tests) get the
  end value as `!SetTransparency to` instead (which `--render`, having no window, ignores).
- Why: macOS uses points (Retina) and a flipped y axis; the manual does not say whether the faded value persists, and
  keeping it transient never changes the user's saved setting behind their back.
- Skin impact: after a refresh the skin starts from its saved AlphaValue again.
- Status: emulated

### SKIN:ReplaceVariables() and SKIN:ParseFormula()
- Windows (Rainmeter): ReplaceVariables replaces variables, section variables included (history). ParseFormula
  evaluates a formula ("formulas … must be entirely enclosed in (parentheses)", plain numbers allowed since a history
  note) and returns nil otherwise.
- Mac (Deskset): same. ParseFormula also replaces variables first and accepts measure names in the formula; an invalid
  formula, an unknown name or an empty string gives nil.
- Why: leniency (a formula with `#Var#` is otherwise always invalid). Judgment call.
- Skin impact: none.
- Status: identical

### Measure objects (SKIN:GetMeasure, SELF)
- Windows (Rainmeter): GetValue, GetStringValue, GetRelativeValue (0.0–1.0), GetValueRange, GetMinValue,
  GetMaxValue, GetOption(name, default, bReplaceMeasures), GetNumberOption(name, default), GetName, Disable, Enable;
  GetMeasure returns nil for an unknown name. SELF is the script's own measure.
- Mac (Deskset): same. GetStringValue is the string after Substitute. GetOption resolves variables, and section
  variables unless bReplaceMeasures is false; it reads !SetOption values; a missing option gives the default or "".
  GetNumberOption gives the default, or 0 (also when the default passed is nil), for a missing or non-numeric option.
  Disable / Enable act at once like `!DisableMeasure` / `!EnableMeasure`. Calling a method with `.` instead of `:`
  raises a clear error ("SKIN:GetVariable() must be called with ':'").
- Why: manual. The nil default and the immediate Disable are judgment calls.
- Skin impact: none.
- Status: identical

### Meter objects (SKIN:GetMeter)
- Windows (Rainmeter): GetOption, GetName, GetX(Absolute), GetY(Absolute) — "If the optional Absolute parameter is
  true, returns the absolute (or "real") X position, which may be different than the defined option" — GetW / GetH
  ("real" size), SetX / SetY / SetW / SetH, Hide, Show.
- Mac (Deskset): GetX() / GetY() are the position relative to the meter's container (the skin for ordinary meters);
  GetX(true) / GetY(true) the position in the skin. GetW / GetH include Padding and are 0 for hidden meters. SetX…SetH
  work like `!SetOption Meter X value` (the option stays set) and move / resize the meter at once so later Get calls
  in the same script see the new value; the full layout follows at the next update or `!Redraw`. SetW / SetH set the
  W / H options (Padding is added to them as usual). Hide / Show work like `!HideMeter` / `!ShowMeter`. GetOption sees
  MeterStyle values. GetNumberOption also works on meters. Meters are laid out at the end of the skin's first
  update; before that (in the main chunk, in Initialize() and in the first Update()) the first Get / Set call lays
  them out provisionally from their options — X / Y with `r` / `R`, W / H, Padding, Hidden, image sizes, and the
  static text of String meters (bound measures with their values at that moment, "0" at load) — without fixing the
  skin's window size (engine.md §1, "Meter geometry before the first update"). API misuse errors count the script's
  own arguments (`m:SetX(nil)` → "bad argument #1 to 'SetX' (number expected, got nil)").
- Why: the manual does not define the non-absolute position for relative (`r` / `R`) meters; the real position is the
  only value that is always meaningful. Judgment call. The provisional layout is also a judgment call: the manual
  does not say when meter geometry exists; before it, every frame was 0 until the end of the first update.
- Skin impact: scripts that expect GetX() to return an `r`/`R` offset get the position instead. Scripts that store a
  meter's position or size in Initialize() (e.g. the start point of an animation) get the value from the options;
  a String meter bound to a measure only has its real width after the first update (Enigma's taskbar width script
  reads the widths again in later updates).
- Status: emulated

### print()
- Windows (Rainmeter): writes to the log in the About window.
- Mac (Deskset): writes to the skin log (Deskset.log) at Notice level as `[MeasureName] text`, values separated by tabs
  like Lua's print. At most 100 lines per second per script (then dropped, logged once); a line longer than 2000
  characters is cut and ends with "…".
- Why: a print in Update at Update=16, or of a multi-megabyte string, must not flood the log file.
- Skin impact: none.
- Status: identical

## !CommandMeasure and inline Lua

### !CommandMeasure
- Windows (Rainmeter): "execute Lua code in the context of a particular script instance … Multiple statements may be
  separated by semicolons (;). All statements are global."
- Mac (Deskset): same; errors are logged as `!CommandMeasure:1: …`. It works on disabled and paused Script measures
  (the manual's examples rely on this). An empty command does nothing.
- Why: manual.
- Skin impact: none.
- Status: identical

### Inline Lua section variables
- Windows (Rainmeter): `[&Script:Function(args)]` calls a function, `[&Script:variable]` reads a global; arguments are
  numbers, formulas (run through Rainmeter's math parser — history), quoted strings, true / false / nil
  (case-insensitive in the skin — history); "any string passed without quoting will be seen by the Lua as a Lua
  variable name". Booleans returned become 1 / 0; nil may not be returned. DynamicVariables=1 is required in options;
  bangs always resolve them. Errors before the first update ("nil" values) are expected.
- Mac (Deskset): same; in an option without DynamicVariables `[&Script:…]` is resolved once, at the first update, like
  every section variable (engine.md §3). Numbers are written in Lua's `tostring` format. A nil result gives an empty
  string (logged); a table or function result, a missing function or a Lua error leaves the section variable
  unresolved (logged).
  Errors that happen before Initialize() has run (while the skin loads) are logged at Debug level only.
  Leniencies: a quote closes a string only when followed by `,` or the end of the list, so values with apostrophes or
  the other quote (`'[&MeasureTitle]'` = `It's "x"`) arrive whole; inside strings `\\ \' \" \n \r \t` are escapes and
  other backslashes are kept (Windows paths); an argument that is neither a number, formula, string nor
  true/false/nil — and text that is not a single name or call (`t.field`) — is evaluated as a Lua expression.
  `[&Script:MaxValue]`-style keywords the engine knows keep their measure meaning.
- Why: manual; leniencies are judgment calls.
- Skin impact: none expected; more argument texts work than on Windows.
- Status: identical

## Standard library on macOS

### io paths and text mode
- Windows (Rainmeter): io functions take Windows paths; relative paths are relative to the process's working folder;
  files open in text mode unless the mode contains `b` ("\r\n" reads as "\n").
- Mac (Deskset): io.open, io.lines, io.input, io.output, os.remove, os.rename, dofile and loadfile accept `\` or `/`;
  a relative path is relative to the skin folder; an existing file is found case-insensitively. Reading from files
  not opened with `b` converts "\r\n" to "\n" (file:read, file:lines, io.read, io.lines), so lines never end in "\r".
  Writing does not add "\r". The default input and `io.stdin` read /dev/null (the app has no console; when it is
  started from a terminal, reading the real standard input would wait for typing and freeze the skin).
- Why: macOS has no text mode and uses `/`; the app's working folder is `/`. Judgment calls.
- Skin impact: CRLF data files and Windows paths work. Reading or writing files in Documents, Desktop or Downloads
  can show a macOS privacy prompt; if it is denied, io.open returns nil and an error message as for any unreadable
  file.
- Status: emulated

### dofile / loadfile
- Windows (Rainmeter): "You must specify a full path"; `SKIN:GetVariable('@')` / `MakePathAbsolute` are recommended;
  history: Unicode paths and errors reporting the right file and line.
- Mac (Deskset): the file is decoded like a script file (UTF-16 libraries work); relative paths are relative to the
  skin folder; errors report `Root/@Resources/Lib.lua:12: …`. Without a file name, `dofile()` raises an error and
  `loadfile()` returns nil and a message, instead of reading standard input.
- Why: consistency with ScriptFile; leniency for relative paths.
- Skin impact: none.
- Status: identical

### os.execute
- Windows (Rainmeter): runs a command through cmd.exe (not restricted by the manual); skins use it mostly as
  `os.execute('start "" "https://…"')` to open a URL, file or program.
- Mac (Deskset): no shell command is run. `start ["title"] [/flags] target [args]`, `cmd /c start …`, `open target`
  and a bare URL or existing file open the target like a `["target"]` action (returns 0). Anything else returns 1 and
  is logged once ("os.execute is not available on macOS"). `os.execute()` returns 0 (no shell).
- Why: Windows commands mean nothing to /bin/sh (some would never end, e.g. `ping -n`), and a blocking shell command
  would freeze the skin.
- Skin impact: commands that only open things work; other commands silently do nothing (status 1).
- Status: partial

### os.getenv
- Windows (Rainmeter): Windows environment variables.
- Mac (Deskset): real variables first; then USERNAME → USER, USERPROFILE / HOMEPATH → HOME, HOMEDRIVE → "",
  APPDATA / LOCALAPPDATA → ~/Library/Application Support, TEMP / TMP → TMPDIR, PROGRAMFILES → /Applications.
  Others are nil.
- Why: common variables scripts use to build paths.
- Skin impact: paths built from them point at the Mac equivalents.
- Status: emulated

### os.date, os.clock and other os functions
- Windows (Rainmeter): the Microsoft C library: `%#d`, `%#H`… remove leading zeros; clock() is wall-clock time since
  the process started.
- Mac (Deskset): `%#x` is emulated (numbers without leading zeros; `!` UTC formats included). os.clock returns
  wall-clock seconds since the app started Lua at launch (the Mac C library would return CPU time, which hardly moves
  for an idle app). os.time, os.difftime, os.tmpname, os.remove, os.rename are the standard ones; locale-dependent
  formats use the C locale on both systems.
- Why: scripts time animations with os.clock and format dates with `%#`.
- Skin impact: none expected. math.random sequences differ from Windows (different C library).
- Status: emulated

## Limits and errors

### Error messages
- Windows (Rainmeter): Lua errors are logged in the About window.
- Mac (Deskset): errors are logged at Error level as `[Measure] Script: Root/Sub/File.lua:12: message` (path relative
  to the Skins folder). Each distinct message is logged once per script instance (at most 100 different ones), so an
  Update() that fails every second does not flood the log. A message longer than 2000 characters (e.g.
  `error(hugeString)`) is cut and ends with "…". API misuse errors point at the script line (not at a tail call,
  where Lua keeps no line).
- Why: log volume.
- Skin impact: repeated errors appear once.
- Status: emulated

### Runaway scripts and memory
- Windows (Rainmeter): not documented (an endless loop freezes Rainmeter).
- Mac (Deskset): each outermost call (main chunk, Initialize, one Update, one !CommandMeasure, one inline call) may
  execute 200 million Lua instructions and run 2 seconds; nested calls share that budget. The instructions are counted
  every 1000 VM instructions; the deadline is also checked at every function call (so a loop of slow library calls,
  such as sorting a huge table, stops at the first call after the deadline) and every 4096 steps of the pattern
  matcher (whose steps count as instructions). A stopped call raises "script stopped after … (endless loop?)" with
  the script line; `pcall`, `xpcall`, `coroutine.resume` and `load` cannot catch it. After 3 stopped calls in a row of
  the same entry point, the script instance stops running until the skin is refreshed (compatibility issue
  "Script [X] was stopped"); its measure keeps its value. Each script state may allocate 64 MB, and all script states
  of the app together 512 MB; beyond that, allocations fail with Lua's catchable "not enough memory" error. Nested
  calls into the same script are limited to 32 levels. `string.rep('', n)` returns at once. Limits are in
  `LuaSupport`.
- Why: a skin must never hang or crash the app. The per-call hook check costs about 5–10 ns per function call in a
  release build. Remaining limitation: one call of a C library function other than the pattern functions runs to
  its end (the slowest ones — sorting or concatenating tens of megabytes — are bounded by the memory limit to about a
  second).
- Skin impact: legitimate scripts are far below the limits (a typical Update takes microseconds).
- Status: emulated

### Threading
- Windows (Rainmeter): scripts run on the skin's thread.
- Mac (Deskset): scripts run on the thread that updates the skin (the main thread), synchronously, like measures.
- Why: skins and their sections are not thread-safe.
- Skin impact: io on slow network volumes blocks the skin while it runs, as on Windows.
- Status: identical
