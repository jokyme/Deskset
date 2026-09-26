# Core plugins (Mac vs Windows)

Rainmeter's bundled plugins that need no Apple UI or media framework, implemented in `DesksetCore`
(`Sources/DesksetCore/Engine/Plugins/`): ActionTimer, CoreTemp, AdvancedCPU, Ping, RunCommand, Quote, FileView,
FolderInfo, RecycleManager, UsageMonitor, PerfMon, ResMon, SpeedFan, WindowMessage and VirtualDesktops, and the
third-party Mouse plugin with Slider, its version 2. AudioLevel, Win7Audio, AppVolume (audio.md) and NowPlaying,
iTunes, WebNowPlaying, MediaKey, WiFiStatus, InputText, FrostedGlass, Chameleon, IsFullScreen, GetActiveTitle, SysColor
(media-ui.md) need AppKit / Core Audio / CoreWLAN: the app implements and registers them at startup. The core plugins
here are registered by DesksetCore itself (`Skin.registerBuiltInExtensions` → `CorePlugins.register()`), so they load
wherever skins load. Mouse and Slider get the skin window's mouse input from whatever shows the skin; Slider's input
from elsewhere on the screen comes from the app's event monitors only (see [Slider](#slider-third-party)), so in
previews, `--render` and the Manage window's checks it sees only the skin's own input.

Sources: the manual pages under https://docs.rainmeter.net/manual/plugins/ (and `/plugins/deprecated/`),
https://docs.rainmeter.net/manual/measures/recyclemanager/ and https://docs.rainmeter.net/manual/measures/ (plugin
measure ranges). VirtualDesktops is not in the manual; only its option names as seen in public forum posts were used.
The Mouse plugin is documented on its own wiki pages, and so is Slider (see [Mouse](#mouse-third-party) and
[Slider](#slider-third-party)). Nothing was taken from Rainmeter's or any plugin's source code.

## General

### Plugin names and aliases
- Windows (Rainmeter): `Measure=Plugin` + `Plugin=Name`, `Name.dll` or `Plugins\Name.dll`
  (https://docs.rainmeter.net/manual/measures/plugin/); RecycleManager "was previously a plugin measure" and also
  works as `Measure=RecycleManager`.
- Mac (Deskset): every form is accepted, case-insensitively: ActionTimer, CoreTemp, AdvancedCPU, PingPlugin / Ping,
  RunCommand, QuotePlugin / Quote, FileView, FolderInfo, RecycleManager (plugin and measure), UsageMonitor,
  PerfMon / PerfMonPlugin, ResMon, SpeedFanPlugin / SpeedFan, WindowMessagePlugin / WindowMessage, VirtualDesktops,
  Mouse, Slider. The plugin forms of the engine's own measures — `Plugin=SysInfo`, `Process`, `WebParser` (former
  plugins) and `PowerPlugin` — are those built-in measures (engine.md §4). A name no module provides is a Windows
  plugin: 0 / "" with a compatibility note; the app's plugin names get a neutral "provided by the Deskset app" note
  instead when DesksetCore runs without the app (engine.md §3).
- Why: legacy skins use every spelling.
- Skin impact: none.
- Status: identical

### Range (MinValue / MaxValue) of plugin measures
- Windows (Rainmeter): measures that cannot know their maximum (the manual names SpeedFan among them) set MinValue /
  MaxValue "dynamically, to the smallest and largest values the measure has been since the skin was loaded"
  (https://docs.rainmeter.net/manual/measures/ "Percentage"); CoreTemp and SpeedFan say MinValue / MaxValue "must be
  added" for percentages.
- Mac (Deskset): every core plugin measure whose number changes — CoreTemp, SpeedFan, AdvancedCPU, UsageMonitor,
  PerfMon, ResMon, Ping, RunCommand, FolderInfo, FileView, RecycleManager — tracks its observed range unless MinValue /
  MaxValue are set (the range starts at 0…1 and only widens, like the engine's Calc / Net / WebParser / Script
  measures). ActionTimer, Quote, WindowMessage, Mouse and Slider (always 0) and VirtualDesktops keep the fixed 0…1
  range.
- Why: judgment — the manual describes this for plugin measures in general.
- Skin impact: bars bound to e.g. CoreTemp Load without MaxValue=100 scale to the largest value seen, as on Windows.
- Status: identical

### Asynchronous work and unloading
- Windows (Rainmeter): plugins do their work in their own threads (ActionTimer, UsageMonitor, Ping, RunCommand, WebParser);
  RunCommand kills hidden programs on refresh / unload.
- Mac (Deskset): nothing blocks the main thread: pings, commands, folder scans, the Trash, per-process sampling run on
  background queues and hand their results to the skin on the main thread (the value is set before the plugin's
  FinishAction runs). When a skin is refreshed or unloaded (`PluginLifecycle.skinWillClose`, or at the latest when the
  measure is released) timers stop, pings are cancelled, sampling stops and hidden RunCommand programs are killed.
- Why: responsiveness; measures are recreated on every refresh.
- Skin impact: a value computed in the background appears at the next update or when the plugin's FinishAction runs.
- Status: emulated

### Windows paths in plugin options
- Windows (Rainmeter): Path / PathName / Folder / StartInFolder / OutputFile / IconPath take Windows paths; the Quote
  example uses `%HOMEDRIVE%%HOMEPATH%\Pictures\`.
- Mac (Deskset): quotes are removed and `\` becomes `/`; `%USERPROFILE%`, `%HOMEDRIVE%%HOMEPATH%`, `%HOMEPATH%` → home
  folder, `%APPDATA%` / `%LOCALAPPDATA%` → `~/Library/Application Support`, `%TEMP%` / `%TMP%` → the temporary folder,
  `%PUBLIC%` → `/Users/Shared`, `%PROGRAMFILES%…` → `/Applications`, `%PROGRAMDATA%` / `%ALLUSERSPROFILE%` →
  `/Library/Application Support`, `%WINDIR%` / `%SYSTEMROOT%` → `/System`, `%USERNAME%` → the user name, other
  `%NAME%` → the process environment, else left as written. `C:\Users\<anyone>\X` → `~/X` with `Videos` / `My Videos`
  → `Movies`, `My Pictures` / `My Music` / `My Documents` → `Pictures` / `Music` / `Documents`, `AppData\Roaming|Local`
  → `Library/Application Support`; `C:\Program Files…\` → `/Applications/`; any other drive-letter path → the same
  path under `/`. `~` is the home folder, relative paths are relative to the skin folder.
- Why: judgment; the Mac has no drives and a different home layout.
- Skin impact: galleries of `%USERPROFILE%\Pictures`, notes in `Documents` etc. work; paths to other drives usually do
  not exist.
- Status: emulated

### Privacy prompts
- Windows (Rainmeter): no prompts.
- Mac (Deskset): reading Desktop, Documents, Downloads, removable or network volumes (Quote / FolderInfo / FileView)
  makes macOS ask the user once; controlling Finder (RecycleManager EmptyBin / EmptyBinSilent, FileView Properties)
  asks once for Automation permission. Denied → empty values / nothing happens, logged once. Nothing is asked unless a
  skin uses the feature. The app's Info.plist carries the texts of these prompts: `NSAppleEventsUsageDescription`
  (Finder), `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
  `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`.
  RecycleManager `Size` needs Full Disk Access, which has no prompt: a compatibility note and the log say where to
  grant it. Slider's watching of the mouse elsewhere on the screen asks for nothing (mouse events only; see
  [Slider](#slider-third-party)).
- Why: macOS privacy protection (TCC).
- Skin impact: a one-time system dialog.
- Status: emulated

## ActionTimer

### ActionList, Wait, Repeat, Execute, Stop, IgnoreWarnings
- Windows (Rainmeter): `ActionListN=Action | Wait ms | Repeat Action, ms, count`; `Execute N` starts a list, a running
  list ignores Execute (warning unless `IgnoreWarnings=1`), `Stop N` ends it; lists run in a separate thread that posts
  each action to the skin (https://docs.rainmeter.net/manual/plugins/actiontimer/).
- Mac (Deskset): identical semantics. Several lists run in parallel; the Wait after the last Repeat is not applied;
  keywords are case-insensitive; `Wait` / `Repeat` not followed by their syntax are action names. A list counts as
  finished when its last action (or the last repetition of a final Repeat) starts, so that action can `Execute` the
  same list again — the usual way to loop an animation, which works on Windows because the plugin's thread has ended
  the list by the time the skin handles the last posted action.
- Why: —
- Skin impact: none.
- Status: identical

### Timing
- Windows (Rainmeter): "as fast as it possibly can", paced only by the Waits; actions are queued as window messages.
- Mac (Deskset): steps run on the main run loop (common modes, so also while a menu is open). The first step runs right
  after the action that sent Execute (never inside it); consecutive actions without Wait run back to back; each Wait is
  counted from the previous step's scheduled time (no drift over long animations); a step more than 100 ms late (busy
  main thread) restarts the schedule from "now" instead of firing the missed steps in a burst; at most 64 actions run in
  one run-loop turn (`Repeat X, 0, 100000` cannot freeze the app). Wait ≤ 0 is no wait; counts are capped at 10 million,
  waits at 24 h.
- Why: AppKit drawing must happen on the main thread; drift-free scheduling is better than sleeping.
- Skin impact: animations are at least as smooth; a skin that floods the queue lags less than on Windows.
- Status: emulated

### Variables in actions
- Windows (Rainmeter): actions are "defined and executed exactly the same as any other Action option"; to use a
  `!SetVariable`-changed `#Variable#` the skin must `!UpdateMeasure` the plugin measure between executions.
- Mac (Deskset): same — `#Variables#` are taken from the measure's last option read (DynamicVariables re-reads them on
  `!UpdateMeasure`), `[SectionVariables]` are resolved when each action runs. ActionListN is parsed when Execute runs.
- Why: —
- Skin impact: none.
- Status: identical

### Judgment calls
- Windows (Rainmeter): not documented.
- Mac (Deskset): commands work while the measure is disabled or paused (these only stop updates); an undefined
  ActionListN or action option is logged; the measure's value is 0.
- Why: judgment.
- Skin impact: none expected.
- Status: emulated

## CoreTemp

### Data source
- Windows (Rainmeter): reads the Core Temp application ("must be running")
  (https://docs.rainmeter.net/manual/plugins/coretemp/).
- Mac (Deskset): no Core Temp app exists; values come from the Mac itself:
  `Load` (CoreTempIndex 0-based) = per-core CPU usage (same source as `Measure=CPU Processor=N+1`);
  `CpuName` = the processor brand string ("Apple M4 Pro"); `CpuSpeed` / `CoreSpeed` = MHz from a sensor source, else
  the rated frequency when macOS reports one (Intel), else 0;
  `MaxTemperature` (default), `Temperature`, `TjMax`, `Vid`, `Tdp`, `Power` = from a `HardwareSensorSource`;
  `BusSpeed` = 100 and `BusMultiplier` / `CoreBusMultiplier` = MHz / 100 only when a sensor source reports
  frequencies, else 0.
- Why: macOS has no public temperature / voltage API (SMC keys differ per chip and need privileges); Apple Silicon has
  no front-side bus.
- Skin impact: load bars and the CPU name work; temperatures read 0 (logged once) until sensor support ships (Pro).
  An unknown CoreTempType is read as MaxTemperature (logged once).
- Status: partial

### Units
- Windows (Rainmeter): Celsius unless Core Temp is set to Fahrenheit.
- Mac (Deskset): always Celsius.
- Why: there is no Core Temp setting to follow.
- Skin impact: none for Celsius skins.
- Status: emulated

## SpeedFan

### Data source
- Windows (Rainmeter): reads the SpeedFan application: `SpeedFanType` Temperature / Fan / Voltage, `SpeedFanNumber`,
  `SpeedFanScale` C / F / K (https://docs.rainmeter.net/manual/plugins/speedfan/).
- Mac (Deskset): the same options index the lists of a `HardwareSensorSource` (temperatures °C converted to F / K,
  fans in RPM, voltages in V); without a sensor source the value is 0 (logged once).
- Why: no SpeedFan on the Mac; no public sensor API.
- Skin impact: 0 until sensor support ships.
- Status: partial

## AdvancedCPU (deprecated)

### Value and units
- Windows (Rainmeter): "a calculation of process CPU time scaled by the number of CPU cores"; a measure without
  CPUInclude / CPUExclude is the maximum for percentages; `Idle` is a placeholder process
  (https://docs.rainmeter.net/manual/plugins/deprecated/advancedcpu/).
- Mac (Deskset): the CPU time the selected processes used since the measure's previous update, in 100 ns units (the
  unit of Windows' process time counters; skins such as Enigma divide by cores × 100000 × seconds to get percent,
  with the core count read from the registry's NUMBER_OF_PROCESSORS, which the Registry measure emulates — engine.md
  §4).
  "Idle" = the idle time of all cores; without CPUInclude / CPUExclude the value is the whole machine
  (≈ cores × seconds × 10⁷), so `MaxValue=[MeasureCPUMax]` works as documented.
- Why: judgment from the manual and from how skins scale the value.
- Skin impact: identical arithmetic.
- Status: emulated

### Processes other users own
- Windows (Rainmeter): every process is visible.
- Mac (Deskset): an unprivileged app can read CPU time only of its own user's processes (about 80 %). The rest
  (WindowServer, kernel_task, root daemons…) is reported together as one process named "System" (busy time of all
  cores minus the visible processes), so totals still add up.
- Why: macOS restricts other users' process information.
- Skin impact: "System" can appear as a top process; exclude it with `CPUExclude=Idle;System` if unwanted.
- Status: emulated

### Names, TopProcess, sampling
- Windows (Rainmeter): process names as Windows shows them (`chrome`), `;`-separated lists, `TopProcess=1` value /
  `=2` name ("the number value is not altered").
- Mac (Deskset): names are the executable names (`Google Chrome Helper (Renderer)`); lists match case-insensitively
  and ignore `.exe`; `Rainmeter` means Deskset itself. `TopProcess=2` keeps the number of `TopProcess=0`. Processes are
  sampled once a second in the background; the value is the latest sample's CPU rate multiplied by the real time since
  the measure's previous update (the sampler and the skin timer are not in step, and skins divide by their own
  interval); the first value uses the sampler's two latest samples.
- Why: Mac process names; no blocking work on the main thread.
- Skin impact: include / exclude lists naming Windows programs match nothing.
- Status: emulated

## UsageMonitor

### Counters
- Windows (Rainmeter): any Windows Performance Monitor Category / Counter / Instance, or an Alias (CPU, RAM,
  RAMSHARED, IO, IOREAD, IOWRITE, GPU, VRAM, VRAMSHARED) (https://docs.rainmeter.net/manual/plugins/usagemonitor/).
- Mac (Deskset): the common counters are emulated (names case-insensitive):
  - Process: `% Processor Time` / `% User Time` / `% Privileged Time` (percent of one core, like Windows; Alias=CPU
    divides by `_Total`), `Working Set - Private` / `Private Bytes` = physical footprint (Activity Monitor's "Memory"),
    `Working Set` = resident size, `Virtual Bytes`, `Thread Count`, `ID Process`, `Elapsed Time`, `Priority Base`,
    `Page Faults/sec`, `IO Read/Write/Data Bytes/sec` = disk I/O of the process; `Handle Count`, `Pool …`,
    `IO … Operations/sec`, `IO Other Bytes/sec`, `Creating Process ID` = 0. Instances: process names plus `Idle`,
    `System` (other users' processes, see AdvancedCPU) and `_Total`.
  - Processor / Processor Information: `% Processor Time` / `% Processor Utility`, `% Idle Time`, `% User Time`,
    `% Privileged Time` from per-core ticks (instances `0`…`N-1` / `0,0`…, `_Total`); `Processor Frequency` (MHz, 0 on
    Apple Silicon without a sensor source); `% Processor Performance` / `% of Maximum Frequency` = 100; interrupt / DPC /
    C-state counters = 0.
  - Memory: `Available Bytes / KBytes / MBytes` (total − used, as the Memory measures count used), `Committed Bytes`
    (used + swap used), `Commit Limit` (RAM + swap), `% Committed Bytes In Use`, `Page Faults/sec` (visible
    processes); cache / pool / paging-rate counters = 0.
  - Paging File: `% Usage`, `% Usage Peak` = swap used / swap total.
  - Network Interface / Network Adapter: `Bytes Received/sec`, `Bytes Sent/sec`, `Bytes Total/sec` per interface
    (`en0`…); `Current Bandwidth` and packet counters = 0.
  - LogicalDisk (`C:`, `_Total` = the startup volume): `% Free Space`, `Free Megabytes`; LogicalDisk / PhysicalDisk
    (`0 C:`, `_Total`): `Disk Read / Write Bytes/sec`, `Disk Bytes/sec` = disk I/O of all visible processes; queue /
    time / transfer counters = 0.
  - System: `Processes`, `Threads`, `System Up Time`, `Processor Queue Length` (1-minute load average),
    `Context Switches/sec`, `System Calls/sec`, `File Read / Write Bytes/sec`.
  - Thermal Zone Information: `Temperature` (K), `High Precision Temperature` (0.1 K) from a sensor source.
  - GPU Engine `Utilization Percentage` (Alias=GPU): one instance "GPU" from a sensor source; GPU Process / Adapter
    Memory (Alias=VRAM, VRAMSHARED): no instances → 0.
  - Anything else → 0, logged once and listed as a compatibility issue.
- Why: macOS has no Performance Monitor; these are the Darwin equivalents (host_processor_info, proc_pidinfo,
  proc_pid_rusage, sysctl, the app's memory / network / disk readings).
- Skin impact: CPU / RAM / IO top-process lists, per-core loads, network and memory counters work; GPU needs sensor
  support; exotic counters read 0.
- Status: partial

### Index, Name, lists, Rollup, Percent, RawValue, PIDToName
- Windows (Rainmeter): Index 0 total ("Total"), -1 average ("Average"), N = Nth highest with its name ("" when its
  value is 0); Name (case-sensitive) overrides Index; Blacklist default `_Total|Idle`, Whitelist overrides it;
  Rollup=1 merges `name#1`…; Percent=1 divides by `_Total` (automatic with Alias=CPU); RawValue=1; PIDToName=1
  (automatic for GPU aliases).
- Mac (Deskset): same rules. Names (Name, Blacklist, Whitelist) match exactly first, then case-insensitively and
  without `.exe`; `Name=Rainmeter` is Deskset; `Rollup=0` names duplicates `name`, `name#1`, `name#2` in pid order;
  ties in Index order are broken by name; the average counts every instance left after the lists; `RawValue=1` gives
  the stored counter (cumulative 100 ns / bytes / counts); PIDToName applies to `ID Process` values.
- Why: Mac process names differ in case from Windows ones.
- Skin impact: Blacklists of Windows services simply match nothing; Mac users may want to blacklist `System`.
- Status: emulated

### Sampling
- Windows (Rainmeter): one thread per Category gathers data once a second regardless of Update / UpdateDivider.
- Mac (Deskset): one shared background sampler takes a sample of all processes and cores once a second while any
  measure needs it (a few milliseconds per sample) and stops when none does; Process / Processor counters use its last
  two samples; memory / network / disk-space counters are read at the measure's update.
- Why: —
- Skin impact: none.
- Status: identical

## PerfMon (deprecated)

### Value
- Windows (Rainmeter): `PerfMonObject` / `PerfMonCounter` / `PerfMonInstance`; `PerfMonDifference=1` (default) uses
  the difference between the current and previous counter value, 0 the current value; names must be English
  (https://docs.rainmeter.net/manual/plugins/deprecated/perfmon/).
- Mac (Deskset): the same counters as UsageMonitor, reported as their stored ("raw") value: with PerfMonDifference=1 the
  change since the measure's previous update (bytes for "…Bytes/sec", 100 ns of idle time for Processor
  "% Processor Time", which is an inverse timer — skins use InvertMeasure=1), with 0 the raw value (counts, bytes).
  An empty PerfMonInstance means `_Total`; an unknown network adapter name means all interfaces. Processor counters are
  read at each update; process-based ones use the once-a-second sample (an update without a new sample keeps its
  value).
- Why: judgment — "the difference between the current and previous counter value" of counters that are cumulative.
- Skin impact: PogPack-style per-core graphs work; unknown counters read 0 (logged, listed as an issue).
- Status: partial

## Ping

### Measurement
- Windows (Rainmeter): round-trip time in ms to `DestAddress`; `UpdateRate` (default 32 updates), `Timeout`
  (30000 ms), `TimeoutValue` (30000), `FinishAction` after a reply or the timeout
  (https://docs.rainmeter.net/manual/plugins/ping/).
- Mac (Deskset): an ICMP echo through an unprivileged datagram socket (IPv4 preferred, IPv6 when the name has only IPv6
  addresses) on a background thread; pings on the first update and every UpdateRate updates; the value is rounded to
  whole milliseconds (so localhost reads 0, like Windows); 0 until the first reply.
- Why: macOS allows ICMP echo without root through `SOCK_DGRAM`.
- Skin impact: none.
- Status: identical

### Failures
- Windows (Rainmeter): not documented beyond the timeout.
- Mac (Deskset): a name that cannot be resolved, no network or a send error count as a timeout: TimeoutValue, then
  FinishAction (the reason is logged once). An empty DestAddress pings nothing (value 0, logged once). `UpdateRate`
  0 or negative pings once, at the first update. A ping still running when the next one is due is not doubled: the
  next ping waits for the following UpdateRate cycle.
- Why: judgment.
- Skin impact: offline skins show TimeoutValue.
- Status: emulated

## RunCommand

### How commands run
- Windows (Rainmeter): `Program` (default `%ComSpec% /U /C`, i.e. cmd.exe) + `Parameter`, run hidden, standard output
  captured (https://docs.rainmeter.net/manual/plugins/runcommand/).
- Mac (Deskset): the command line runs through `/bin/sh -c` (the Mac counterpart of `cmd.exe /C`), in the skin folder
  (or `StartInFolder`), with stdin from /dev/null, the app's environment, a PATH that also contains
  `/opt/homebrew/bin` and `/usr/local/bin`, and `LANG=<user's locale>.UTF-8` (else `en_US.UTF-8`) when the app has no
  locale variables (apps started from Finder have none, and programs would print non-ASCII text as `?`); each run is
  its own process group. An empty Program, `cmd`, `cmd.exe`, `%ComSpec%` or a path ending in `cmd.exe` (with any of
  `/U /C /K /Q /D /S`) means "the Parameter is the command line"; a Mac Program (`python3`, `/usr/bin/osascript`, a
  shell…) is run with the Parameter appended. Like Windows' "Program Parameter" command line, Program may carry
  arguments of its own (`Program=python3 -u`): the program is a quoted first word, else the longest leading part that
  names an existing file (Mac paths may contain spaces), else the first word. Quotes (`"…"` and `'…'`), backslash
  escapes and redirections such as `2>&1`, `>&2`, `&>file` reach the shell unchanged.
- Why: POSIX commands are the Mac's command-line programs.
- Skin impact: skins written with portable commands (`curl …`, `echo`, `whoami`, `hostname`) work unchanged.
- Status: emulated

### Windows-only commands
- Windows (Rainmeter): any Windows program or cmd.exe command.
- Mac (Deskset): these are never passed to the shell: PowerShell / pwsh / wscript / cscript / mshta / rundll32 and other
  Windows tools, cmd.exe built-ins without a Mac counterpart (`dir`, `copy`, `del`, `rd`, `md`, `move`, `ren`,
  `timeout`, `tasklist`, `taskkill`, `wmic`, `reg`, `netsh`, `where`, `tree`, …), programs ending in
  `.exe .bat .cmd .com .ps1 .vbs .js .wsf .msc .msi .lnk .cpl .scr .hta .reg` (also as Program with arguments, e.g.
  `Program=powershell.exe -NoProfile`), command lines containing a cmd.exe variable, drive-letter paths (`C:\…`) or
  UNC paths. The run fails with error 103 before anything starts (logged once per command).
  - A cmd.exe variable is `%NAME%` / `%NAME:~0,4%` whose name has two or more characters and is either a known
    cmd.exe variable (`%date%`, `%UserProfile%`, `%ComSpec%`…) or written in capitals (`%MYVAR%`); `date +%Y%m%d`
    and other strftime formats are not variables.
  - Names cmd.exe shares with POSIX commands or shell keywords — `find`, `sort`, `more`, `date`, `time`, `set`, `if`,
    `for`, `rmdir`, `netstat`, `route`, `arp`, `ipconfig`, `type` — run through the shell unless the command uses
    Windows syntax: a `/switch` argument (`/s`, `/Q`, `/?`, `/a:h`, `/+3`, or `/word` that is not an existing folder
    such as `/all`), an `if` without `then` (`if exist x …`), a `for` whose loop variable is `%x` / `%%x`, or a bare
    `ipconfig` (Windows prints the configuration, the Mac only its usage). So `ps aux | sort -nr`, `date +%H:%M`,
    `find . -name '*.txt'`, `for f in *; do …; done`, `ipconfig getifaddr en0` work, `date /t`, `sort /r`,
    `rmdir /s /q x` fail with 103.
  - Translated because the meaning is clearly the same: `start ["title"] target` and `explorer target` →
    `/usr/bin/open target` (also as `Program=explorer`); Windows `ping` with `-n N`, `-w ms`, `-l size`, `-4` → macOS
    `ping -c N -W ms -s size` (4 echoes by default, as on Windows; `-t` and other options → 103), while a Mac ping
    line (it has `-c`) runs unchanged (also as `Program=ping`, since a Mac ping without a count never ends); `type
    file…` (without `-` options) → `cat file…` with `\` in the file names turned into `/`; cmd.exe's `&` separator →
    `;` (`&&`, `||`, `|` unchanged; `&` inside quotes or in a redirection is not a separator); redirections to
    cmd.exe's `NUL` device (`2>nul`) → `/dev/null`.
- Why: running Windows command lines in another shell could do something different from what the author meant, while
  Mac skins (and portable Windows ones) must be able to use ordinary POSIX command lines.
- Skin impact: PowerShell / WMIC-based info skins show nothing (error 103); portable and Mac command lines work.
- Status: partial

### FinishAction after a failed start (judgment)
- Windows (Rainmeter): FinishAction runs "when the program has finished / exited"; error 103 is "Cannot start
  program".
- Mac (Deskset): after error 103 the FinishAction still runs, right after the current action, so skins that wait for it
  (e.g. to replace "Loading…") move on — except when the previous start of the same measure also failed less than one
  second earlier (a FinishAction that runs the command again would loop).
- Why: judgment — graceful degradation for Windows-only commands.
- Skin impact: skins show an empty result instead of waiting forever.
- Status: emulated

### Values and error codes
- Windows (Rainmeter): number -1 before the first run, 0 while running, 1 on success, 100 unknown command, 101 still
  running, 102 not running, 103 cannot start, 104 cannot save file, 105 cannot terminate, 106 cannot create pipe;
  string = standard output.
- Mac (Deskset): the same codes. The program's exit status does not matter (a missing Mac command prints "not found" on
  stderr and still gives 1, like cmd.exe). Standard error is discarded (`2>&1` in the command line keeps it). Output is
  capped at 16 MB. Options changed with `!SetOption` are read when Run starts (leniency). When the program has ended,
  its output is decoded and OutputFile written on a background queue; then the value, the string and FinishAction
  follow, so a FinishAction that reads OutputFile finds it complete. During those milliseconds Run answers 101.
- Why: —
- Skin impact: none.
- Status: identical

### State, Close, Kill, Timeout
- Windows (Rainmeter): `State` Hide / Show / Minimized / Maximized; hidden programs are killed on refresh / unload;
  Close sends a close message, Kill terminates; Timeout closes (or kills with State=Hide) and FinishAction runs "even
  if the program does not actually terminate".
- Mac (Deskset): command-line programs have no window, so State only decides whether a running program is killed on
  refresh / unload (Hide, the default) or left running. Close = SIGTERM, Kill = SIGKILL, both to the whole process
  group. Timeout sends SIGTERM (SIGKILL with State=Hide) and finishes the run with the output received so far
  (value 1). A program that is still running one second after Close (it ignores SIGTERM) is no longer waited for: the
  run finishes (value 1, FinishAction), as the manual says for Close. Programs left behind this way are still killed
  on refresh / unload with State=Hide. A program that has ended is never signalled again (its process id may belong to
  another program by then).
- Why: no console windows on the Mac.
- Skin impact: none.
- Status: emulated

### Output encoding and OutputFile
- Windows (Rainmeter): `OutputType` UTF16 (default) / UTF8 / ANSI tells the plugin how the program writes and how
  OutputFile is encoded; OutputFile defaults to the skin folder.
- Mac (Deskset): output is decoded as UTF-8 (UTF-16 with a BOM, else Windows-1252 when it is not valid UTF-8) whatever
  OutputType says; line ends stay `\n`. OutputFile (relative to the skin folder, folders created) is written in the
  OutputType encoding: UTF16 = UTF-16 LE with BOM, UTF8 = UTF-8 without BOM, ANSI = Windows-1252.
- Why: Mac programs write UTF-8.
- Skin impact: `Substitute="#CRLF#":""` style cleanup works (`#CRLF#` is `\n`).
- Status: emulated

## QuotePlugin

### Items and randomness
- Windows (Rainmeter): `PathName` file → a random part split by `Separator` (default `#CRLF#`); folder → a random file
  (`Subfolders` default 1, `FileFilter` `*.jpg;*.png`) (https://docs.rainmeter.net/manual/plugins/quote/).
- Mac (Deskset): same. A new random item at every update of the measure (UpdateDivider sets the pace), never the same
  item twice in a row when there is a choice; `\r\n` and `\n` both end lines; blank parts, hidden files, Finder files
  (`.DS_Store`…) and package contents are skipped; the file is decoded like skin files (UTF-8 / UTF-16 / ANSI). The
  number value is 0.
- Why: judgment where the manual is silent.
- Skin impact: none.
- Status: identical

### Reading
- Windows (Rainmeter): not documented.
- Mac (Deskset): the file or folder is read on a background queue when the options change and again when the list is
  older than a minute (new pictures show up); the first item appears as soon as the list is read (even with
  UpdateDivider=-1); a missing or unreadable path gives "" (logged once). At most 100 000 items.
- Why: no file I/O on the main thread.
- Skin impact: the value is empty for a moment after loading.
- Status: emulated

## FolderInfo

### Counting
- Windows (Rainmeter): `Folder` (path or `[OtherMeasure]`), `InfoType` FileCount / FolderCount / FolderSize,
  `RegExpFilter`, `IncludeSubFolders`, `IncludeHiddenFiles`, `IncludeSystemFiles`
  (https://docs.rainmeter.net/manual/plugins/folderinfo/).
- Mac (Deskset): same options. `Folder=[Measure]` reuses that measure's scan. Missing / unknown InfoType = FolderSize
  (judgment). RegExpFilter (PCRE) is matched against file names and only matching files are counted and summed.
  Hidden = dot files and files with the hidden flag; system = Finder / file-system bookkeeping files (`.DS_Store`,
  `.localized`, `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `._*`, `Icon\r`…); a hidden or system folder is skipped
  with its contents. Packages (`.app`) are folders; symbolic links count as files and are not followed; sizes are
  logical file sizes. At most 2 million entries per scan.
- Why: Mac file attributes.
- Skin impact: counts can differ slightly from Explorer's for the same data.
- Status: emulated

### Scanning
- Windows (Rainmeter): scans on update ("very large" folders can make Rainmeter unstable).
- Mac (Deskset): scans on a background queue at each update of the measure, at most one at a time; the value changes
  when the scan ends. After a scan that took `d` seconds the next one waits at least `2 × d` (a huge folder then keeps
  a background thread busy at most a third of the time; folders that scan in milliseconds are not affected).
  Unreadable folders count as 0 (logged once).
- Why: no file I/O on the main thread.
- Skin impact: large folders never freeze the skin.
- Status: emulated

## FileView

### Parent and children
- Windows (Rainmeter): a parent measure reads `Path` (default "This PC"); children (`Path=[Parent]`) read `Index`
  1…Count (wrapping) with `Type` FolderPath / FolderSize / FileCount / FolderCount / FileName / FileType / FileSize /
  FileDate / FilePath / PathToFile / Icon; the disk is read only at load and with the Update command
  (https://docs.rainmeter.net/manual/plugins/fileview/).
- Mac (Deskset): same model. The parent's string is the current folder (ending in `/`) and its number the count of
  listed items (judgment); the default path is `/Volumes/` (the mounted volumes); folders are read on a background
  queue, and the parent and all its children get their new values before FinishAction runs; PageUp / PageDown /
  IndexUp / IndexDown update the children at once. `Update` re-reads the folder navigated to, or the new Path after
  `!SetOption` / `!SetVariable` changed it (the `#Variables#` of Path are resolved again for Update, so no
  DynamicVariables are needed — the manual's "use Update after changing options").
- Why: —
- Skin impact: none.
- Status: identical

### Listing rules (judgment)
- Windows (Rainmeter): Explorer-like listing; ShowHidden default 1, ShowSystem default 0.
- Mac (Deskset): `..` first (not at `/`), then folders, then files, each group sorted by SortType (Name uses Finder's
  natural order; Size; Type = extension; Date = SortDateType) — SortAscending=0 reverses within the groups. Hidden = dot
  files and the hidden flag; system = Finder bookkeeping files (see FolderInfo). Links to folders (e.g.
  `/Volumes/Macintosh HD`) are folders. FileCount / FolderCount / FolderSize follow the hidden / system / Extensions /
  WildcardSearch filters but not ShowFile / ShowFolder. `Recursive=1` makes those totals include subfolders (links
  not followed); `Recursive=2` indexes every matching file of the tree (FollowPath / PreviousFolder disabled, as
  documented; at most 200 000 files are indexed, the counts and size still cover all of them). WildcardSearch (other than `*`) also filters the listed folders, but not the folders Recursive
  descends into.
- Why: judgment where the manual is silent.
- Skin impact: order and counts match Finder rather than Explorer.
- Status: emulated

### Types
- Windows (Rainmeter): FileDate is a "system date"; FileSize is empty for folders; FolderPath / PathToFile end with `\`.
- Mac (Deskset): FileDate is the short date and time of the user's locale (number: seconds since 1601 like the Time
  measure); FileSize is a number (so AutoScale works) and "" for folders; paths use `/` and folder paths end with `/`;
  FilePath of `..` is the parent folder; HideExtensions removes the extension from file names only.
- Why: Mac paths and locale formats.
- Skin impact: skins that parse `\` out of paths need `/`.
- Status: emulated

### Icons
- Windows (Rainmeter): `Type=Icon` writes the item's icon as `iconN.ico` in the skin folder (or `IconPath`), size
  Small 16 / Medium 32 / Large 48 / ExtraLarge 256.
- Mac (Deskset): same file names and sizes; the image is written by the app's icon writer (`FileViewIcons.writer`,
  Finder's icon for the file) on a background queue, and the value is the file path once it exists. Without the writer
  the value is empty (logged once). The file is only rewritten when the item or size changes.
- Why: extracting icons needs AppKit.
- Skin impact: none in the app and in `--render` (both install the writer, `FileViewIconWriter.install()`); in
  core-only contexts (DesksetSelfTest) the icon values stay empty.
- Status: emulated

### Commands
- Windows (Rainmeter): FollowPath (folder → navigate, file → open), Open, PreviousFolder, ContextMenu (Explorer's
  context menu), Properties (Explorer's properties dialog), each also with a path for the parent.
- Mac (Deskset): FollowPath / Open / PreviousFolder as documented (files open in their default app, folders in Finder
  with Open); ContextMenu reveals the item in Finder (another app's Finder context menu cannot be shown); Properties
  opens Finder's Get Info window (Automation permission for Finder, asked once).
- Why: no API to show Finder's context menu from another app.
- Skin impact: right-click menus become "show in Finder".
- Status: partial

## RecycleManager

### Count and Size
- Windows (Rainmeter): `RecycleType=Count` (default) / `Size` of the Recycle Bin
  (https://docs.rainmeter.net/manual/measures/recyclemanager/).
- Mac (Deskset): the Trash: `~/.Trash` plus `.Trashes/<uid>` of the other internal volumes (external and network
  volumes are left out — reading them triggers a permission prompt). Count works without any permission (directory
  entry counts; Finder's `.DS_Store` / `.localized` are not items). macOS protects the Trash's contents, so Size needs
  Full Disk Access for Deskset; without it Size is 0, and a compatibility note (`RecycleManagerMeasure.sizeNote`) and
  the log say how to grant it — the note is taken back once the size can be read. Readings happen on a background
  queue (count every update, size when the Trash changes or every 30 s) and are shared by all RecycleManager measures;
  the first reading is shown as soon as it arrives. The old `Drives=` option is ignored (all volumes count).
- Why: macOS privacy protection of `~/.Trash`.
- Skin impact: "items in the Trash" skins work; size skins show 0 until Full Disk Access is granted.
- Status: partial

### OpenBin, EmptyBin, EmptyBinSilent
- Windows (Rainmeter): open the bin; empty it after confirmation; empty it silently.
- Mac (Deskset): OpenBin opens the Trash in Finder. Emptying goes through Finder (AppleScript), like Finder ▸ Empty
  Trash: EmptyBin shows a Finder confirmation dialog first ("Are you sure you want to permanently erase the items in the
  Trash?"), EmptyBinSilent empties without it; nothing happens when the Trash is empty. Finder's own warning (its
  `warns before emptying` setting, on by default, which also applies to scripted emptying) is switched off for the
  `empty` command only and restored right after — also when emptying fails — so EmptyBin asks exactly once and
  EmptyBinSilent never. macOS asks once whether Deskset may control Finder; if refused, nothing is emptied.
- Why: the Trash is Finder's; this keeps Finder's own handling (locked items, other volumes).
- Skin impact: a one-time Automation prompt.
- Status: emulated

## ResMon

### Resource counts
- Windows (Rainmeter): `ResCountType` GDI (default) / USER / Handle / Window, optionally for `ProcessName`
  (https://docs.rainmeter.net/manual/plugins/resmon/).
- Mac (Deskset): `Handle` = open file descriptors — of every process named ProcessName (`.exe` dropped; `Rainmeter` =
  Deskset) that the user may inspect, else of the whole system (`kern.num_files`); GDI, USER and Window = 0. Finding the
  processes of a name means reading every process's name (~10 ms), so it happens on a background queue every 10
  seconds (new processes of that name count from then on; the value is 0 until the first lookup is done); counting the
  descriptors at each update is cheap.
- Why: macOS has no GDI / USER objects; file descriptors are the nearest thing to handles.
- Skin impact: GDI / USER displays read 0.
- Status: partial

## WindowMessage

### SendMessage and window titles
- Windows (Rainmeter): sends window messages (`WindowMessage=msg wParam lParam`, `!CommandMeasure … "SendMessage …"`) to
  a window found by WindowName / WindowClass and returns the result or the window's title
  (https://docs.rainmeter.net/manual/plugins/windowmessage/).
- Mac (Deskset): value 0, string "", commands ignored (logged once).
- Why: macOS has no window messages; other apps' window titles need the Screen Recording permission.
- Skin impact: Winamp-style controls do nothing.
- Status: not supported

## VirtualDesktops

### Desktops
- Windows (Rainmeter): a plugin for the Dexpot / VirtuaWin desktop managers (not in the manual).
- Mac (Deskset): a single desktop: `VDMeasureType=VDMActive` 0, `DesktopCount` / `DesktopCountX` / `DesktopCountY` 1,
  `CurrentDesktop` 1, `DesktopName` "Desktop 1", anything else 0 / ""; commands (switching, screenshots) are ignored.
- Why: macOS Spaces have no public API.
- Skin impact: desktop pagers show one desktop.
- Status: not supported

## Mouse (third-party)

Mouse.dll (by NighthawkSLO, later versions maintained by others) runs actions on mouse input anywhere on a skin;
settings skins use it for drag sliders. Deskset implements it in DesksetCore (`MousePlugin.swift`) from its public
documentation only: the Documentation wiki page of https://github.com/NighthawkSLO/Mouse.dll and that page's history,
the PluginMouse wiki page of https://github.com/jsmorley/PluginMouse (version 3.2.2), the release notes, the plugin's
example skins and published skins that use it. Its source code was not read. The skin window hands the plugin its input
through `Skin.pointerEvent` (the skin window's mouse rules are in app.md).

### Actions, $MouseX$ / $MouseY$, RelativeToSkin
- Windows (Rainmeter): "The plugin reads and executes all action options but not limited to a meter" (the options of
  https://docs.rainmeter.net/manual/mouse-actions/), plus `MouseMoveAction` ("gets executed when the mouse moves") and
  `LeftMouseDragAction`, `RightMouseDragAction`, `MiddleMouseDragAction`, `X1MouseDragAction`, `X2MouseDragAction`
  ("when their respective mouse button is pressed and the mouse moves - these do not override the MoveAction but are
  executed after it"). "In the same way as existing mouse actions do it, the plugin's actions substitute temporary
  variables $MouseX$ and $MouseY$ with the mouse coordinates"; `RelativeToSkin=0` makes "the monitor's top-left corner
  the 0,0 coordinate, instead of the skin's top-left corner" (default 1)
  (https://github.com/jsmorley/PluginMouse/wiki/PluginMouse).
- Mac (Deskset): the Down, Up and DoubleClick actions of the left, right, middle, X1 and X2 buttons, the four
  MouseScroll actions (one per wheel notch; trackpads as for meters), MouseMoveAction (also under `MoveAction`, its name
  in version 3.0.0), the five drag actions after MouseMoveAction, and MouseOverAction / MouseLeaveAction when the
  pointer comes over the skin / leaves it. A double click runs the DoubleClick action and then the Down action, as a
  meter does ("both will be executed"). `$MouseX$` / `$MouseY$` (any case, as in version 2.2.2) are whole points from
  the skin's top-left corner; with RelativeToSkin=0 they are screen coordinates with 0,0 at the primary screen's
  top-left corner, the coordinates `!Move` uses. `$MouseX:%$` / `$MouseY:%$` stay as written (only the two are
  documented). The measure's value is 0.
- Why: judgment for the hover actions ("all action options") and for "the monitor" (Windows screen coordinates start at
  the primary monitor's corner).
- Skin impact: none expected.
- Status: identical

### Where the input comes from
- Windows (Rainmeter): version 3.2 "uses [a] process hook instead of a global one, better for sliders" (release notes):
  it sees the mouse input of Rainmeter's own windows, where earlier versions hooked the mouse globally. Forum posts
  about the plugin report that without RequireDragging a drag no longer reaches it once the pointer leaves the skin.
- Mac (Deskset): the skin window's own input: presses, releases, wheel notches and moves over the skin, and — for a
  press that started on the skin — every drag and the release until the button goes up, also while the pointer is
  outside the skin. A press that started elsewhere is never a drag of the skin. ⌘-presses (the CTRL override, see
  app.md) and Control-clicks (the Mac's right click, which opens the skin menu) are not reported. A release that never
  arrives (a menu took it) is reported with the next pointer move.
- Why: macOS hands a press's drags and release to the window where it started. Dropping them would stop sliders short of
  their ends, and a lost release leaves skins half-way through a drag (settings skins turn their Mouse measure off in
  its LeftMouseUpAction). Skins written for the versions with a global hook expect the drag to go on.
- Skin impact: a slider follows the pointer past the skin's border without RequireDragging too. Clicks in other apps
  never reach the plugin (as with version 3.2).
- Status: emulated

### Order with the skin's own mouse actions
- Windows (Rainmeter): not documented.
- Mac (Deskset): the Mouse measures get an event (in file order) before the meters and `[Rainmeter]` do: a press on a
  slider runs the measure's LeftMouseDownAction, then the meter's.
- Why: judgment — the plugin watches the mouse input before the skin window handles it.
- Skin impact: when a meter's LeftMouseDownAction starts or enables the measure, the measure's own LeftMouseDownAction
  does not run for that press (published skins set the first value in the meter's action); its drag and release do.
- Status: emulated

### RequireDragging, Start and Stop
- Windows (Rainmeter): "RequireDragging can be set to 1 to make the plugin accept commands with arguments Start and Stop
  to set mouse capturing to happen outside borders aswell - very useful for implimenting dragging" (default 0).
- Mac (Deskset): with RequireDragging=1 the measure accepts `!CommandMeasure M "Start"` / `"Stop"` (any case, also while
  it is disabled or paused) and runs its actions only between them. Without RequireDragging, Start and Stop are ignored
  with a warning in the log. Following a press outside the skin needs no Start (see above).
- Why: judgment — the plugin's example skin (`Dragging.ini`) and published skins start the measure from the
  LeftMouseDownAction of the meter being dragged and stop it in the measure's own LeftMouseUpAction, and skins with one
  such measure per slider rely on only the started one reacting.
- Skin impact: none expected.
- Status: emulated

### Disabled, paused and DynamicVariables
- Windows (Rainmeter): "Without this option [RequireDragging], the plugin's measure can be paused or disabled but it has
  to have DynamicVariables=1 and be updated."
- Mac (Deskset): a disabled or paused measure runs no action, from the bang on; after `!EnableMeasure` /
  `!UnpauseMeasure` its options are read before the next input even without an update. The documented way
  (DynamicVariables=1 and `!UpdateMeasure` after the bang) works as well. A button pressed on the skin while the measure
  was disabled still drags once it is enabled.
- Why: judgment; nothing in skins depends on the actions going on until the next update.
- Skin impact: none expected (settings skins enable the measure from a MouseOverAction and disable it again after the
  release, some without an update).
- Status: emulated

### UpdateRate
- Windows (Rainmeter): documented for version 3.0 only: "UpdateRate can be set from default 20 to set the interval (in
  milliseconds) for executing the plugin's move and drag actions". Version 3.1 moved to "threading instead of timers"
  and the option left the documentation; skins still carry `UpdateRate=20` (Monstercat Visualizer's settings skins, for
  example).
- Mac (Deskset): move and drag actions run at most once per UpdateRate milliseconds (default 20; 0 = on every move; at
  most 10 000). A move within the interval waits; only the newest waiting position runs, when the interval ends or right
  before the measure's next other action, so a release always comes after the final drag position.
- Why: judgment — the documented meaning; it also spares skins whose drag action writes a file (`!WriteKeyValue`) on
  every move.
- Skin impact: by default move and drag actions run at most 50 times a second; the last position is never lost.
- Status: emulated

### Options of older versions
- Windows (Rainmeter): version 3.0 also documented `NeedsFocus=1` ("only allow the plugin to work if it's skin is
  currently selected"), which the later documentation no longer has; versions 2.x were a plugin named Slider
  (`Plugin=Slider.dll`: ClickAction, ReleaseAction, HoldAction, MoveAction, DragAction, MouseButton).
- Mac (Deskset): `NeedsFocus` is ignored. `Plugin=Slider` is a measure of its own with version 2's options (see
  [Slider](#slider-third-party)); a Mouse measure does not read them.
- Why: NeedsFocus is no longer in the plugin's documentation.
- Skin impact: a Mouse measure with NeedsFocus=1 also runs its actions while its skin does not have the focus (moves
  over the skin, and the click that gives it the focus).
- Status: partial

## Slider (third-party)

Slider.dll (by NighthawkSLO) is version 2 of the Mouse plugin, under its first name: it runs actions when one mouse
button is pressed, held, dragged and released, and when the mouse moves, anywhere on the screen. Settings windows and
scroll bars still load it (VisBubble's and BassBeat's settings windows, NXT-OS), and so does a mouse overlay
(Keystrokes). Deskset implements it in DesksetCore (`SliderPlugin.swift`) on the Mouse plugin's input model, from its
public documentation only: the 2016 revisions of the Documentation wiki page of https://github.com/NighthawkSLO/Mouse.dll
(versions 2.1.0.26 to 2.2.2.41, in the page's history) and the release notes of versions 1.1.1.15 to 3.2.0. Its source
code was not read. The app watches the mouse elsewhere on the screen for it (`OutsidePointerMonitor.swift`).

### Options and actions
- Windows (Rainmeter): `MouseButton` picks the button to track: Left (default), Right or Middle. `ClickAction` and
  `ReleaseAction` run when it is pressed and released, `DragAction` when it is pressed and the mouse moves,
  `HoldAction` when it is held for `HoldDelay` milliseconds, and `MoveAction` when the mouse moves. All actions replace
  `$MouseX$` and `$MouseY$` with the mouse coordinates; `RelativeToSkin=0` makes the monitor's top-left corner 0,0
  instead of the skin's (default 1) (https://github.com/NighthawkSLO/Mouse.dll/wiki/Documentation, the revision of
  2016-05-18). Version 2.2.2.41 made the two variables case-insensitive.
- Mac (Deskset): those options and actions. MouseButton is read in any case; any other value is the left button, with a
  warning in the log. MoveAction also runs during a drag, before DragAction. A double click is one more press
  (ClickAction again). `$MouseX$` / `$MouseY$` (any case) and RelativeToSkin work as in the Mouse plugin: whole points,
  and with RelativeToSkin=0 screen coordinates from the primary screen's top-left corner. Version 3's options
  (LeftMouseDownAction, UpdateRate, RequireDragging…) are not read, `!CommandMeasure` has no commands, and options
  that skins set but the documentation does not have (`MoveDelay` in Keystrokes) are ignored. The value is 0.
- Why: judgment for MoveAction during a drag (version 3 documents its drag actions as running after its move action)
  and for other MouseButton values.
- Skin impact: none expected. With MouseButton=Right a right click still opens the skin menu on release, unless a
  meter's right-button action keeps it closed.
- Status: identical

### Which input it gets
- Windows (Rainmeter): not documented as such. Version 1.1.1.15 ran "like a while loop" with no cooldown, version
  2.0.0.24 on "a detached thread with a 20 ms cooldown", and version 3.2 "Uses process hook instead of a global one"
  (release notes): the versions before it watched the mouse on the whole screen, and the documentation of version 2 ties
  none of its actions to the skin ("ClickAction and ReleaseAction get executed when a mouse button is pressed or
  released", "MoveAction gets executed when a the mouse moves"). Published skins expect clicks anywhere on the screen:
  Keystrokes lights up its mouse buttons for every click, and VisBubble's settings window checks that it has the focus
  before it handles a click, closing its pop-up menus when the click was elsewhere. Version 2 has no wheel, hover or
  double-click actions.
- Mac (Deskset): input on the skin as for the Mouse plugin (see [Mouse](#mouse-third-party)): presses of the tracked
  button on the skin, followed with their drags and release until the button goes up, also outside the skin, and moves
  over the skin; ⌘-presses and Control-clicks on the skin are not reported; a lost release is reported with the next
  move. Input elsewhere on the screen — in other apps, on the desktop, on the transparent parts of skins, over a skin
  that is hidden or lets the mouse through (ClickThrough), and in Deskset's other windows (another skin, the skin
  editor, the Manage window) — runs the same actions: ClickAction and ReleaseAction for the tracked button, DragAction
  and HoldAction for its presses made there, MoveAction for every move and every drag. `$MouseX$` / `$MouseY$` are then
  outside the skin (from its top-left corner, so negative or beyond its size), and with RelativeToSkin=0 screen
  coordinates from the primary screen's top-left corner, on any screen. A skin's own window reports its own input and
  never twice. The measures get the skin's own input before the meters, in file order; input from elsewhere reaches only
  Slider measures (not the Mouse plugin's), in file order. A Control-click elsewhere is a press of the left button (the
  button pressed). A release that never arrived is reported with the next press of that button or the next move.
- Why: judgment — the whole-screen watching of the versions before 3.2, which skins written for version 2 rely on.
- Skin impact: none expected: Keystrokes shows every click, and VisBubble closes its pop-up menus on a click elsewhere.
  A skin whose Slider measure is always on runs its ClickAction for clicks anywhere, as on Windows.
- Status: emulated

### Watching the mouse elsewhere on the screen
- Windows (Rainmeter): a hook or a polling thread; nothing is asked of the user.
- Mac (Deskset): AppKit's event monitors — a global one for the events of other apps, a local one for Deskset's own
  windows — for mouse events only, which macOS allows without any permission (only key events would need Accessibility,
  and keys are never watched). They exist only while a loaded skin has an enabled, unpaused Slider measure whose actions
  need them, and they watch only what those actions need: the tracked button's presses and releases (for a Click,
  Release, Drag or Hold action), its drags only while a press of it made elsewhere is held (Drag or Hold: a hold's
  position follows the pointer), and every move and drag (MoveAction). So another app's drags reach Deskset only during
  such a press, or when a MoveAction wants every move. They go as soon as no such measure remains: disabled, paused, the
  action removed, the skin unloaded or refreshed without it, Deskset quitting. Previews, `--render`, the Manage window's
  checks and the self-tests never watch the mouse. The input is handed to the skins on the main thread right after macOS
  reports it, in order; moves waiting together are handed over as the newest one, and move and drag actions keep their
  20 ms cooldown. The drags and the release of a press made in one of Deskset's own windows are followed by reading the
  pointer every 20 ms until the button goes up, because that window's controls take those events before any monitor sees
  them.
- Why: macOS has no global mouse hook without the Accessibility permission; event monitors see other apps' mouse input
  without one.
- Skin impact: clicks in Deskset's own menus (a skin menu, the menu bar menu) are not seen, and moves over Deskset's
  windows other than skins may be missed. A drag or release in Deskset's own windows arrives up to 20 ms late. With a
  MoveAction, the action runs whenever the mouse moves anywhere (at most 50 times a second), as on Windows.
- Status: emulated

### HoldAction and HoldDelay
- Windows (Rainmeter): HoldAction runs when the tracked button is held for HoldDelay milliseconds (default 300; 500
  until version 2.2.1.38 brought a "new, better way of doing HoldAction"). Nothing else is documented.
- Mac (Deskset): once per press, when the button is still down HoldDelay milliseconds after the press, whether the
  pointer moved meanwhile or not, with `$MouseX$` / `$MouseY$` where the pointer is then; a release before that ends
  the hold. A drag position still waiting for its 20 ms runs first. A negative HoldDelay counts as 0.
- Why: judgment — the documentation only says "held for a delay".
- Skin impact: none expected.
- Status: emulated

### Move and drag actions at most every 20 ms
- Windows (Rainmeter): version 2.0.0.24 runs on its own thread "with a 20 ms cooldown" (release notes); the first
  documentation adds that the actions run whatever the skin's Update is.
- Mac (Deskset): MoveAction and DragAction run at most once every 20 ms, outside the skin's update cycle; only the
  newest waiting position runs, when the 20 ms end or right before the measure's next other action, so a release or a
  hold always comes after the final drag position. ClickAction, HoldAction and ReleaseAction run at once.
- Why: judgment — the documented cooldown; it also spares skins whose drag action runs a script, updates the skin and
  writes a file on every move (VisBubble's settings window does all three).
- Skin impact: at most 50 move / drag actions a second; the last position is never lost.
- Status: emulated

### Disabled and paused
- Windows (Rainmeter): not documented for version 2.
- Mac (Deskset): as for the Mouse plugin: a disabled or paused measure runs nothing, from the bang on, and a measure
  turned on is active at once. A measure turned on during a press on the skin drags, holds and releases that press,
  but its ClickAction does not run for it, because the measure gets the press before the meter that turns it on
  (NXT-OS's scroll bars turn theirs on from the track's LeftMouseDownAction and off in the measure's ReleaseAction).
  The mouse elsewhere on the screen is not watched for a disabled or paused measure: a press made elsewhere while it
  was off is not followed once it is on, and a press made elsewhere before it was turned off gets no ReleaseAction
  later.
- Why: judgment; the Mouse plugin's rules, and no watching of the mouse that no action needs.
- Skin impact: none expected.
- Status: emulated
