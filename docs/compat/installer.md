# Skin installer (.rmskin, legacy Rainstaller packages, plain ZIPs, folders)

Code: `Sources/DesksetCore/Rmskin/` (`Rmskin.swift` .rmskin packages and the installer, `RmskinLegacy.swift` legacy
Rainstaller packages / plain archives / folders / fonts / themes, `RmskinZip.swift` ZIP safety and extraction,
`RmskinFiles.swift` file and INI-text helpers). Tests: `RmskinTests.swift`, `RmskinLegacyTests.swift`
(`swift run DesksetSelfTest rmskin`). Original sample packages: `TestSkins/Installer/`.

Sources: the manual pages
[Installing Skins](https://docs.rainmeter.net/manual/installing-skins/),
[Distributing Skins](https://docs.rainmeter.net/manual/distributing-skins/),
[Advanced .rmskin Options](https://docs.rainmeter.net/tips/advanced-rmskin-options/),
[@Resources folder](https://docs.rainmeter.net/manual/skins/resources-folder/),
[@Vault](https://docs.rainmeter.net/manual/distributing-skins/vault-folder/),
[@Include](https://docs.rainmeter.net/manual/skins/include-option/),
[Manage → Layouts](https://docs.rainmeter.net/manual/user-interface/manage/),
the [version history](https://docs.rainmeter.net/history/), and the files of real packages downloaded for local
testing (never copied into the repository). The Rainstaller configuration keys are not documented in the manual; their
meaning below is inferred from their names and from packages seen in the wild.

## What can be installed

| Input | Rainmeter (Windows) | Deskset (Mac) |
| --- | --- | --- |
| `.rmskin` made by the Skin Packager (ZIP + 16-byte footer, `RMSKIN.ini`) | installed | installed |
| `.rmskin` with the footer but without `RMSKIN.ini` | refused | refused ("no RMSKIN.ini") — unless it holds a `Rainstaller.cfg` |
| legacy `.rmskin` made for Rainstaller (no footer, `Rainstaller.cfg`) | refused since 2.3/2.4 | installed |
| plain ZIP renamed `.rmskin`, or a `.zip`, with `RMSKIN.ini` | refused since 2.3 | installed |
| plain ZIP without any manifest (`.rmskin` or `.zip`) | manual installation by the user | installed (root configs detected) |
| an already extracted folder (skin folder, package folder, folder of skins) | manual installation by the user | installed (copied, never moved) |
| a ZIP (or folder) with no skin that wraps one `.rmskin` (typical download-site ZIP) | user extracts it, then double-clicks the .rmskin | the inner package is installed |
| a ZIP (or folder) with no skin that holds several `.rmskin` files | user extracts and installs each | refused, naming the packages (`.severalPackages`) |
| `.rar`, `.7z` | manual installation by the user | not supported — extract, then install the folder |

API: `RmskinPackage.inspect(_:)` takes a `.rmskin` / `.zip` file or a folder, `RmskinPackage.inspect(folder:)` a
folder, `RmskinPackage.canInspect(_:)` tells an app what to offer, `RmskinManifest.packageFormat` says which format
was found (`.rmskin`, `.rainstaller`, `.plain`), `RmskinInspection.fontNames` / `RmskinInstallResult.installedFonts`
list the fonts the installation adds. New errors: `.alreadyInSkinsFolder` (a folder that is, contains or lies in the
Skins folder) and `.severalPackages([names])`.

## Package files and extraction

### Plain ZIP files renamed to .rmskin
- Windows (Rainmeter): "As of version 2.3, Rainmeter will not install a normal ZIP file changed to the '.rmskin'
  extension; the package must be created with the Skin Packager." ([Distributing Skins](https://docs.rainmeter.net/manual/distributing-skins/))
- Mac (Deskset): a file without the footer is accepted when it is a ZIP. With `RMSKIN.ini` it installs like a
  packager-made .rmskin; with `Rainstaller.cfg` as a legacy package; with neither, root configs are detected (see
  "Plain archives" below). The extension does not matter (`.rmskin` or `.zip`).
- Why: judgment call. Many packages on skin sites are exactly such files (hand-zipped or made for the old
  Rainstaller); refusing them only sends users to do the same steps by hand.
- Skin impact: packages that Rainmeter 4 refuses install on the Mac.
- Status: emulated

### Footer present but no RMSKIN.ini
- Windows (Rainmeter): the Skin Packager always writes RMSKIN.ini; a package without it cannot be installed.
- Mac (Deskset): a file ending with the `\0RMSKIN\0` footer must contain `RMSKIN.ini` (or `Rainstaller.cfg`), else
  `.missingManifest` ("The package has no RMSKIN.ini"). Root-config detection is only used for files *without* the
  footer.
- Why: a footer means "made by the packager", so a missing manifest means a damaged file.
- Skin impact: none for working packages.
- Status: identical

### Footer ZIP length
- Windows (Rainmeter): the footer holds the ZIP length; the manual does not describe padding.
- Mac (Deskset): the first `length` bytes are the ZIP; bytes between it and the footer are ignored. A length of 0 or
  larger than the file is a damaged package.
- Why: the manual is silent.
- Skin impact: none.
- Status: identical

### Wrapper folders
- Windows (Rainmeter): the packager puts `RMSKIN.ini` at the top. The version history mentions "Rainstaller: Fixed a
  bug when there was no top level folder in a .rmskin", so legacy packages exist both with and without a wrapper.
- Mac (Deskset): `RMSKIN.ini` / `Rainstaller.cfg` are looked for at the top of the archive and below up to three
  wrapper folders that are each the only *folder* of their parent — loose files beside them (a read-me, a preview
  image) do not matter (`PogPack 1.3/Rainstaller.cfg`, `Downloads/Suite 2.0/Rainstaller.cfg`,
  `Suite 2.0/RMSKIN.ini` + `Read me.txt`). For a folder being installed, the folder itself counts as one more level.
- Why: real legacy packages are wrapped (one of the test packages is). Before the review a read-me next to the
  wrapper made the manifest invisible, so the package installed as a plain archive and silently lost its
  `VariableFiles` / `MergeSkins` / load settings.
- Skin impact: wrapped packages install with their manifest settings.
- Status: emulated

### Extraction safety
- Windows (Rainmeter): not documented.
- Mac (Deskset): before anything is written the ZIP directory is checked — absolute paths, drive letters, `..`
  components (with `/` or `\`), NUL bytes and symbolic-link entries are refused, as are archives over 200 000 entries or
  4 GB. `ditto` extracts; its real output is watched and stopped when it outgrows what the archive declares (ZIP bombs),
  with a 300-second timeout. Afterwards links / special files / `__MACOSX` are removed, permissions are normalised,
  names containing `\` become folders, and non-UTF-8 names are read as code page 437. Resource forks, ACLs and extended
  attributes in the archive are dropped; the download's quarantine flag is passed on to every extracted file, so
  Gatekeeper keeps checking anything a skin launches. The same rules apply to every format (legacy and plain archives
  included).
- Why: macOS security; skins never need links.
- Skin impact: a package containing symbolic links (even harmless ones) is refused.
- Status: emulated

### Unrelated archives are refused early
- Windows (Rainmeter): n/a.
- Mac (Deskset): a ZIP without the footer whose directory lists no `.ini` file (Windows' `desktop.ini` does not count)
  and no `Rainstaller.cfg` is refused with "The package doesn't contain any skins" before anything is extracted —
  unless it lists a `.rmskin` file and declares at most 512 MB, see "Archives that wrap a .rmskin". Archives whose
  only .ini files are in `@…` folders, in `Layouts/`, or loose in a `Skins` folder are refused after extraction for
  the same reason.
- Why: dropping a photo archive on the app must not unpack gigabytes.
- Skin impact: none.
- Status: emulated

### Names that are not UTF-8
- Windows (Rainmeter): "Support Unicode characters in skin paths when creating or installing .rmskin files" (3.1).
- Mac (Deskset): UTF-8 names are used as is; legacy names are decoded as code page 437 (the ZIP default) when ditto
  escapes them. ditto decodes some legacy names itself using the Mac's legacy text encoding, so on a Mac set to a
  different language a CP437 name can come out differently.
- Why: ditto/Archive Utility behaviour.
- Skin impact: rare odd characters in folder names of very old packages.
- Status: partial

### Hidden files
- Windows (Rainmeter): "The Skin Packager will ignore any hidden files or folders in your root config folder."
- Mac (Deskset): files and folders whose names start with `.` and `__MACOSX` are never installed, from any format, and
  neither are Windows Explorer's hidden system files `desktop.ini`, `Thumbs.db` and `ehthumbs.db` (any case); none of
  them counts as a skin when root configs are detected. A backup of an existing skin keeps everything.
- Why: same rule; macOS zips add `.DS_Store` / `__MACOSX` debris, and ZIPs made on Windows can carry Explorer's
  hidden files. A `desktop.ini` is an INI file: before the review, one at the top of a ZIP made the whole archive a
  single root config (`Pack\Suite\Clock` instead of `Suite\Clock`), and a photo folder with a `desktop.ini`
  installed as a "skin" that was loaded after installing.
- Skin impact: none (a skin file literally named `desktop.ini` would not install; Windows Explorer reserves that name).
- Status: identical

## RMSKIN.ini (the Skin Packager's manifest)

### Key names
- Windows (Rainmeter): the manual documents the packager's fields (Name, Author, Version, load a skin / layout after
  installation, minimum Rainmeter / Windows version, header image, Variables files, Merge skins) but not the key names.
- Mac (Deskset): `[rmskin]` keys `Name`, `Author`, `Version`, `LoadType`, `Load`, `VariableFiles` (`|`-separated),
  `MergeSkins` (also the older `Merge`), `MinimumRainmeter`, `MinimumWindows`; every key is kept in `manifest.raw`.
  UTF-8, UTF-16 and ANSI files are read.
- Why: the key names the packager fields map to.
- Skin impact: none observed (all 13 packager-made test packages parse).
- Status: identical

### Minimum Rainmeter / Windows version
- Windows (Rainmeter): the installer refuses a package whose minimum Rainmeter or Windows version is not met.
- Mac (Deskset): a minimum Rainmeter version newer than 5.0 (`MinimumRainmeter`, or `MinRainmeterVer` of legacy
  packages) adds a warning to the install confirmation; the package can still be installed. Revisions are ignored, so
  `5.0.0.5291` counts as 5.0 (`RmskinManifest.requiresNewerRainmeter`). The minimum Windows version is ignored.
- Why: Deskset implements Rainmeter 5.0's skin features, so a newer requirement may mean a missing feature, but refusing
  the package would also block skins that do not need it. Windows versions mean nothing on macOS.
- Skin impact: a package made for a newer Rainmeter installs after the warning; unsupported features degrade and are
  reported by the engine.
- Status: emulated (Rainmeter version) / not supported (Windows version)

### Header image
- Windows (Rainmeter): "a valid 400x60 .bmp file" (enforced by the packager since 3.2.1).
- Mac (Deskset): `RMSKIN.bmp` is shown when it is a real Windows bitmap of at most 4096 px either way; the exact size is
  not required (older packages predate the check). Anything else is ignored with a note.
- Why: robustness against crafted headers.
- Skin impact: none.
- Status: identical

### More than one root config
- Windows (Rainmeter): the packager takes one root config folder.
- Mac (Deskset): every folder in `Skins/` except `@Vault` is installed as a root config; loose files in `Skins/` are
  ignored with a note.
- Why: hand-made and legacy packages often hold several.
- Skin impact: suites split over several root configs install completely.
- Status: emulated

## Installing

### Replacing an installed skin and backups
- Windows (Rainmeter): existing skins are backed up and replaced; Advanced → Backup skins can disable the backup
  ([Installing Skins](https://docs.rainmeter.net/manual/installing-skins/)).
- Mac (Deskset): Advanced → Backup skins is checked by default for each package. When enabled, a replaced root config
  is moved to `Backups/<RootConfig>` (then `(2)`, `(3)`… so older backups are kept). Turning it off skips that permanent
  skin backup. The new folder is staged and swapped in; a failed swap restores the old folder regardless of the
  checkbox. Existing layout backups in `Backups/@Layouts/` remain separate from the skin-backup choice.
- Why: skin replacement and its backup selection share the existing transactional installation path.
- Skin impact: disabling Backup skins replaces the old skin files without retaining a permanent skin backup.
- Status: emulated. The manual does not specify whether Backup skins affects layout backups; the existing Mac layout
  backup behavior is retained.

### Merge skins
- Windows (Rainmeter): Merge skins adds or replaces package files without removing other files or backing up the
  root config; it takes precedence over Variables files
  ([Advanced .rmskin Options](https://docs.rainmeter.net/tips/advanced-rmskin-options/)).
- Mac (Deskset): modern packages with an `RMSKIN.ini` manifest and `MergeSkins=1` (or its `Merge` alias) copy package
  files over the installed folder without removing unrelated files. They do not create a skin backup or preserve
  old variable values, regardless of the Backup skins checkbox. Legacy Rainstaller Merge retains its existing
  compatibility behavior: it can retain a backup and apply its variable-preservation settings.
- Why: modern installation follows the documented precedence; legacy package handling remains separate.
- Skin impact: modern patches retain files absent from the package, while packaged files and variables replace the
  old versions. Legacy behavior is unchanged.
- Status: emulated (modern rules); legacy variable and merge combinations remain a compatibility difference.

### Variables files
- Windows (Rainmeter): variables present in both versions retain their old values; other lines come from the package.
  Variables files is skipped when Merge skins is enabled or the user disables Backup skins
  ([Advanced .rmskin Options](https://docs.rainmeter.net/tips/advanced-rmskin-options/)).
- Mac (Deskset): modern `RMSKIN.ini` packages preserve listed variable files only when skin backup is enabled, a backup
  directory is provided, and Merge skins is off. Every `[Variables]` key present in both versions keeps the user's
  exact value, including empty values. The package keeps its layout, comments, new keys and encoding; text outside
  that encoding switches to UTF-16 LE. `@Include…` options always come from the package. Out-of-package paths and `..`
  produce a note rather than being followed. Legacy Rainstaller `KeepVar` and variable lists retain their previous
  behavior, including preservation without a backup or during a legacy merge.
- Why: modern backup and merge choices control variable preservation without changing legacy package handling.
- Skin impact: modern installs with Backup skins off, or with Merge skins on, use the package's variable values.
- Status: emulated (modern rules); legacy preservation without backup or during merge differs from modern Rainmeter.

### Plugins
- Windows (Rainmeter): 32/64-bit DLLs are installed to the Plugins folder (newer versions are kept) and archived in
  `@Vault`.
- Mac (Deskset): never installed nor archived; the confirmation lists the DLL names and warns that skins using them show
  no data (the engine's plugin area emulates some well-known plugins).
- Why: Windows DLLs cannot run on macOS.
- Skin impact: parts of skins that rely on third-party plugins stay empty unless Deskset emulates the plugin.
- Status: not supported

### Layouts
- Windows (Rainmeter): installed to the Layouts folder and optionally applied; "Remove all [Rainmeter] section options
  from layouts installed by a .rmskin" (2.5 history).
- Mac (Deskset): installed to `Layouts/<name>` with every `[Rainmeter]` option removed. Selecting Apply included layout
  first closes all old skins before replacing package files. Close actions run against the old files; their resulting
  settings are captured for `@Backup` using the old variant list. The installed layout then loads through the same
  coordinator as `!LoadLayout`. If closing exceeds the total 10-second budget, installation stops without replacing
  package files and reports the failure. Without that selection the layout is installed only.
- Why: the application handles the lifecycle without restarting its process; the installer continues to reject load
  targets outside this package.
- Skin impact: compatible suites can arrange their skins after installation. See [Layouts](layouts.md) for the native
  INI format, global-setting differences, macOS wallpaper limits and filesystem-dependent variant ordering.
- Status: emulated

### Loading a skin after installation
- Windows (Rainmeter): the author can request a skin or layout to load after installation; the user can skip that
  action ([Distributing Skins](https://docs.rainmeter.net/manual/distributing-skins/#Step2)).
- Mac (Deskset): Load included skins is checked by default when the package requests a skin. Clearing it installs
  the files without activating that requested target. Previously running skins from replaced roots reload their
  previous variants when those files still exist. With the option selected, `LoadType=Skin` + `Load=Config\File.ini`
  loads the installed target once; an invalid or external target only produces a note. Apply included layout remains
  a separate choice for packages that request a layout. Choices reset for each package.
- Why: installation and the author's requested post-install action are independent choices.
- Skin impact: a package can be installed without loading its requested skin or replacing the desktop with its layout.
- Status: emulated

### @Vault
- Windows (Rainmeter): the `@Vault` folder holds shared resources and archived plugins.
- Mac (Deskset): a package's `Skins/@Vault` or top-level `@Vault` is merged into `Skins/@Vault` without replacing
  existing files; plugins are not archived there.
- Why: Windows DLLs are useless on macOS.
- Skin impact: none.
- Status: partial

### Interrupted installation
- Windows (Rainmeter): not documented.
- Mac (Deskset): if the app is killed mid-install, hidden `.deskset-install-*` / `.deskset-old-*` folders can remain in
  the Skins folder; they are not deleted automatically because `.deskset-old-*` may hold the user's only copy.
- Why: safety over tidiness.
- Skin impact: none (hidden folders are not scanned).
- Status: emulated

## Fonts

### Package Fonts folder (legacy .rmskin and Rainstaller packages)
- Windows (Rainmeter): legacy packages' `Fonts\` folder was installed into `Windows\Fonts` (with admin rights; no
  longer supported since 2.4). Skins made after 2012 ship fonts in `@Resources\Fonts`, which "are automatically loaded
  and can be used with the FontFace option".
- Mac (Deskset): TrueType / OpenType fonts (`.ttf .otf .ttc .otc`, any case) found anywhere in the package's `Fonts/`
  folder — and loose font files at the top of the package — are copied into `@Resources/Fonts` of **every** installed
  root config, flat (subfolders are not kept, because only the top of `@Resources/Fonts` is loaded). A font of the same
  file name already there (any case: the skin's own copy or the user's) is never replaced. Nothing is installed into
  `~/Library/Fonts` or `/Library/Fonts`; fonts are registered for Deskset only when a skin of that root config loads.
  With no skin in the package, the fonts are not installed (note shown). `installedFonts` lists what was added.
  The manual names TrueType and OpenType; `.ttc` / `.otc` collections are copied and loaded from `@Resources/Fonts`
  too (the engine and the app accept all four extensions, any case).
- Why: system-wide font installation needs no admin rights on macOS but would change every other app's font list and
  is not undoable from Deskset; the engine already loads `@Resources/Fonts` automatically.
- Skin impact: old skins that expected their fonts to be installed system-wide show the right font. The fonts are not
  available to other Mac apps. A package with several root configs gets a copy in each. The app reads the
  `@Resources/Fonts` folders of the installed root configs again right after an installation (and every folder again
  when a skin loads or is refreshed, and on Refresh All): fonts added, replaced or removed by reinstalling a root
  config that is already loaded take effect at once, and running skins lay their text out again with them.
- Status: emulated

### A root config's own Fonts folder, and fonts next to the skins
- Windows (Rainmeter): only `@Resources\Fonts` is loaded automatically; a `Fonts` folder beside `@Resources`, or a
  font file lying next to the skin's .ini files, is not. The skin's read-me usually asks the user to install the font
  by hand.
- Mac (Deskset): fonts in `<RootConfig>/Fonts/` (any depth) and font files loose at the top of `<RootConfig>/` are also
  copied into that root config's `@Resources/Fonts` (the originals stay), from every package format, without
  replacing a font already there. Other root configs of the package do not get them. Fonts deeper in config folders
  are not looked for.
- Why: judgment call — the manual step a Windows user would do. Seen in three real packager-made packages: Elegant
  Watch (`<RootConfig>/Fonts`), eClock and HDD Usage Bars (font next to the .ini files; added in the review — their
  clock face and pixel font now render instead of a fallback).
- Skin impact: those skins show their intended font without a manual step.
- Status: emulated

### Font formats macOS cannot use
- Windows (Rainmeter): Windows bitmap fonts (`.fon`, `.fnt`) and Type 1 fonts (`.pfb`, `.pfm`, `.pfa`) install.
- Mac (Deskset): they are not installed; the confirmation names them.
- Why: macOS does not load these formats.
- Skin impact: text falls back to a similar Mac font.
- Status: not supported

## Legacy Rainstaller packages

### Rainstaller.cfg
- Windows (Rainmeter): used by Rainstaller (Rainmeter 1.x–2.3); current Rainmeter no longer installs these packages.
- Mac (Deskset): read like RMSKIN.ini (UTF-8, UTF-16, ANSI; section and keys case-insensitive; every key kept in
  `manifest.raw`). Mapping:

  | Rainstaller.cfg `[Rainstaller]` | Deskset (.rmskin model) |
  | --- | --- |
  | `Name`, `Author`, `Version` | same |
  | `MinRainmeterVer` | `minimumRainmeter` (warns when newer than 5.0) |
  | `Merge=1` | `mergeSkins` |
  | `KeepVar` | see below |
  | `LaunchType`, `LaunchCommand` | `loadType`, `load` (see below) |
  | `AdminRights`, `RainmeterFonts` | ignored (they chose where Windows put fonts and plugins) |

  When a package has both RMSKIN.ini and Rainstaller.cfg, RMSKIN.ini wins.
- Why: the keys are undocumented; the mapping follows their names and real packages.
- Skin impact: legacy packages install with their name, author, version, merge and load settings.
- Status: emulated

### KeepVar
- Windows (Rainmeter): undocumented Rainstaller option (keep the user's variables on reinstall).
- Mac (Deskset): a number (or `true`/`false`, `yes`/`no`, `on`/`off`) is a switch — `KeepVar=1` keeps the user's
  `[Variables]` values in **every** `.ini` / `.inc` file of the package's root configs (at most 2 000 files), with the
  Variables-files rules above (so `@Include…` lines always come from the new version); `0` or empty keeps nothing.
  Any other value is read as a `|`-separated file list, exactly like `VariableFiles`.
- Why: judgment call from the option's name.
- Skin impact: reinstalling a legacy suite keeps the user's customisations. A new version that intentionally changed a
  default variable keeps the user's older value (as with VariableFiles).
- Status: emulated

### LaunchType / LaunchCommand
- Windows (Rainmeter): undocumented; real packages use `LaunchType=Theme` with a theme name, or `LaunchType=Load` with
  `Config\File.ini`.
- Mac (Deskset): `Theme` / `Layout` (also `LoadTheme`, `LoadLayout`) → load a layout (a trailing `\Rainmeter.thm` is
  dropped); `Load` / `Skin` / `Config` (also `LoadSkin`, `LoadConfig`, `ActivateConfig`) → load a skin; a command
  written as a bang is understood (`!ActivateConfig` / `!ToggleConfig` "Config" ["File.ini"], `!LoadLayout` /
  `!LoadTheme` Name, with or without the old `Rainmeter` prefix, bare or bracketed like an action option
  `[!ActivateConfig …]`; only the first bang counts). A skin command naming only a config folder loads its
  first `.ini` in Finder order. An empty type is inferred from the command (`.ini` → skin, else layout). Any other type
  (e.g. running a program) is reported and nothing is loaded.
- Why: judgment call; never run programs from a package.
- Skin impact: legacy packages can load their skin or apply their converted layout when selected.
- Status: emulated

### Themes → Layouts
- Windows (Rainmeter): "Changed the term 'Themes' to 'Layouts' throughout Rainmeter" (2.4, October 2012). Legacy
  packages carry `Themes\<name>\Rainmeter.thm`, which has the Rainmeter.ini layout format.
- Mac (Deskset): each `Themes/<name>` folder becomes `Layouts/<name>` with `Rainmeter.thm` (or the folder's only `.thm`
  file) renamed `Rainmeter.ini`, then installs like any layout (global `[Rainmeter]` options removed). A theme whose
  name a layout of the same package already uses is skipped with a note. Other files (wallpapers) are kept. Applies to
  every package format.
- Why: themes are the old layouts.
- Skin impact: see [Layouts](layouts.md); converted layouts can be applied when selected.
- Status: emulated

### Addons
- Windows (Rainmeter): legacy `Addons\` (Windows programs such as configuration tools) went to `Rainmeter\Addons`.
- Mac (Deskset): never installed; a note says so. Programs a skin ships inside its own folder are copied as files but
  cannot run.
- Why: Windows executables cannot run on macOS.
- Skin impact: buttons that launch those tools do nothing.
- Status: not supported

## Plain archives (no manifest)

### Finding the root configs
- Windows (Rainmeter): manual installation — "Extract … Locate the skin folder (may be nested within a 'Skins' parent
  folder) … Move the folder to the Rainmeter 'Skins' folder … Refresh all."
  ([Installing Skins](https://docs.rainmeter.net/manual/installing-skins/))
- Mac (Deskset): the same steps, automated. Rules in order (names case-insensitive, hidden items ignored, skins = `.ini`
  files at most 12 levels deep outside `@…` folders):
  1. A `Skins` folder holding skin folders, at the top or below up to three single wrapper folders
     (`Pack 1.3/Skins/Pack/…`), makes the archive a package: its `Skins/*`, `Fonts/`, `Layouts/`, `Themes/`, `Plugins/`,
     `Addons/`, `@Vault` are used as in a .rmskin.
  2. An archive whose top has `.ini` files or `@Resources` is itself one root config, named after the archive file
     (`Tiny Clock.zip` → `Tiny Clock`; `/ \ :` become `-`, leading dots / `@` and trailing dots / spaces are dropped).
  3. Otherwise every top folder containing skins is a root config. A single such folder is only treated as a wrapper
     (and its sub-folders as the root configs) when it has no `.ini` / `@Resources` itself and a folder below it —
     through at most three single wrappers — has `@Resources`, or is the folder the skins address as
     `#SKINSPATH#Name\…` (read from the first 64 `.ini` / `.inc` files). Without such a mark the single folder is the
     root config (`Suite/Clock/Clock.ini` installs as root config `Suite`). Folders named `Skins`, `Fonts`, `Plugins`,
     `Addons`, `Layouts`, `Themes` or starting with `@` are never root configs; `Fonts/`, `Plugins/`, `Addons/`,
     `Layouts/`, `Themes/`, `@Vault` and loose font files at the top or next to a wrapper are package components.
- Why: judgment call; the manual only says the folder may be nested. `@Resources` belongs to a root config, and
  `#SKINSPATH#Name\` in old skins names the folder they must be installed as — a wrong guess breaks their image paths.
- Skin impact: most "extract to Skins" archives install correctly. Known misreadings (the skins still run in each case,
  only their config names differ):
  - a wrapper with no `@Resources` and no `#SKINSPATH#` hint below it is kept as the root config, so the configs get
    one extra level (`Wrapper\Name\Clock`);
  - an archive made of a root config's *contents* whose skins sit in config folders and which has no `@Resources`
    (e.g. `Drive C/…`, `Drive D/…` at the top) installs each config folder as its own root config; zipped with its
    folder it installs correctly;
  - a folder with several skin folders of which only one has an `@Resources` of its own (a config-level
    `@Resources`) is taken for a wrapper, and its config folders become root configs;
  - a ZIP of a layout folder (`Desk/Rainmeter.ini`) installs as a root config holding one "skin" (layouts are only
    recognised in `Layouts/` or `Themes/`);
  - a root config literally named `Fonts`, `Plugins`, etc. is not recognised.
- Status: emulated

### What is installed from a plain archive
- Windows (Rainmeter): whatever the user moves.
- Mac (Deskset): only the root configs (and the package components above). Read-me files, previews and wallpapers
  outside the root configs are left out; folders left out are named in a note, loose documents are not.
- Why: the user would not move them into Skins either.
- Skin impact: none.
- Status: emulated

### Name and auto-load
- Windows (Rainmeter): n/a (manual installation loads nothing; the user loads skins from Manage).
- Mac (Deskset): the confirmation shows the single root config's name, else the wrapper's or archive's name, with no
  author / version. When the archive holds exactly one skin (`.ini` file) it is loaded after installing; with more,
  nothing is loaded and the Manage window shows the new root config. Layouts in a plain archive are installed but never
  scheduled to load.
- Why: judgment call — with one skin there is nothing to choose.
- Skin impact: single-skin downloads appear on the desktop right away.
- Status: emulated

### Reinstalling from a plain archive
- Windows (Rainmeter): the user overwrites or replaces the folder by hand.
- Mac (Deskset): same as a .rmskin without MergeSkins / VariableFiles: the old root config is backed up and replaced.
- Why: consistency.
- Skin impact: settings the user changed inside the skin files are in the backup, not in the new version.
- Status: emulated

## Folders

### Installing an extracted folder
- Windows (Rainmeter): manual installation (move the folder into Skins).
- Mac (Deskset): `inspect(folder:)` (also `inspect(_:)` / `install(packageURL:)` with a folder) accepts an extracted
  .rmskin (with RMSKIN.ini), a legacy Rainstaller folder, a single skin folder or a folder of several root configs. The
  folder is first **copied** to a temporary folder — never moved or changed — skipping hidden items, symbolic links
  (not followed; noted) and special files, within the archive limits (200 000 items, 4 GB, 100 levels). The copy keeps
  the chosen folder as its top item, so detection sees it exactly like a ZIP made *of that folder*: the chosen folder
  is the root config (named after it) unless it is marked as a wrapper — a `Skins` folder inside it, sub-folders with
  their own `@Resources`, or a `#SKINSPATH#Name\` reference (see "Finding the root configs"). A folder without any
  `.ini` (`desktop.ini` aside) is refused before copying, unless it holds `.rmskin` files (see "Archives that wrap a
  .rmskin"). A folder that is, contains or lies inside the Skins folder is refused (`.alreadyInSkinsFolder`) when
  installing.
- Why: "Move the folder to the Rainmeter 'Skins' folder" — the folder the user picks is what they would move. Before
  the review the folder's *contents* were examined instead, so a root config without `@Resources` whose skins sit in
  config folders (the corpus's `Mnml Drives`) was split into one root config per config folder.
- Skin impact: none. A folder that merely collects unrelated single-skin root configs without `@Resources` installs as
  one root config holding them (`Folder\Clock`); the skins still run.
- Status: emulated

### Archives that wrap a .rmskin
- Windows (Rainmeter): the Skin Installer opens `.rmskin` files only; a download delivered as a ZIP holding the
  `.rmskin` (and often a read-me or preview) has to be extracted first.
- Mac (Deskset): a ZIP without footer that has no skin (`.ini`) and no `Rainstaller.cfg` but lists a `.rmskin` file,
  and declares at most 512 MB, is extracted; if it holds exactly one visible `.rmskin` (at any depth), that package is
  inspected and installed as if it had been opened directly (its own temporary folder; the wrapper's is removed). A
  folder without skins holding exactly one `.rmskin` is handled the same way. With several packages the installer
  refuses with `.severalPackages` naming them. Only one level is opened: a `.rmskin` that is itself a wrapper is not
  unwrapped again.
- Why: judgment call — download sites commonly serve the package inside a ZIP; the 512 MB cap keeps an archive inside
  an archive from doubling the extraction limits.
- Skin impact: those downloads install in one step.
- Status: emulated

### .rar and .7z archives
- Windows (Rainmeter): the manual's manual-installation steps mention .zip, .rar and .7z.
- Mac (Deskset): only ZIP-based files are opened; extract other archives (e.g. with Archive Utility or The Unarchiver)
  and install the folder.
- Why: macOS has no built-in RAR/7-Zip extractor with the safety checks above.
- Skin impact: one extra step for those downloads.
- Status: not supported

## Skin Packager

### Making a package (Create .rmskin Package…)
- Windows (Rainmeter): Manage → "Create .rmskin package...": Name, Author, Version, one root config folder, layouts,
  plugin pairs (32-bit and 64-bit; the other one is looked up by swapping `32bit` / `64bit` in the folder name), then
  the output folder (Desktop), Load skin / Load layout, the minimum Rainmeter version, and on the Advanced tab the
  400×60 header bitmap, Variables files and Merge skins (mutually exclusive). Load previous (Shift deletes), Back.
  Hidden files are skipped; the result is `Name_Version.rmskin`.
- Mac (Deskset): `RmskinPackager` (DesksetCore) checks the settings (`problems`) and writes the package (`build`);
  `SkinPackagerWindowController` is the window, opened from the box icon next to "Create new skin" above Manage's skin
  list (with the selected skin's root config); a text button in the bottom bar would push Manage past its minimum width.
  - Layout: `RMSKIN.ini`, optional `RMSKIN.bmp`, `Skins/<root>/…`, `Layouts/<name>/…`, `Plugins/32bit|64bit/<dll>`;
    ZIP from `ditto -c -k --norsrc --noextattr --noacl --noqtn`, then the 16-byte footer.
  - `RMSKIN.ini`: UTF-16 LE with BOM, CRLF; keys Name, Author, Version, LoadType/Load (only with a choice),
    VariableFiles (` | `), MergeSkins=1 (only when set), MinimumRainmeter. No MinimumWindows (removed in 5.0).
    Line breaks in fields become spaces.
  - Names: staged with POSIX `mkdir` / `copyfile` in Unicode form C (Foundation's file APIs would decompose them), and
    the UTF-8 flag (bit 11) is set in every central record and local header (`RmskinZip.markNamesUTF8`), since ditto
    writes UTF-8 names without it.
  - Left out: names starting with `.`, `desktop.ini`, `Thumbs.db`, `ehthumbs.db`, `__MACOSX`, Finder-hidden items,
    symbolic links (reported in the result).
  - Checks: name, author, a root config with at least one `.ini` outside `@Resources`, layouts with `Rainmeter.ini`,
    complete plugin pairs with the same file name, the skin or layout to load being part of the package, a real
    400×60 BMP header, Variables files inside the root config (case-insensitive), not with Merge skins, a version like
    `5`, `5.0` or `5.0.0.4657`, an output folder.
  - Plugin version from the PE header's machine type (0x14C x86, 0x8664 x64); counterpart by swapping `32bit`/`64bit`
    or `x86`/`x64` folder components.
  - Defaults (judgment calls): minimum Rainmeter 5.0; empty Name/Author/Version filled from the folder and its first
    skin's `[Metadata]`; "Load skin" set to that skin. Unsafe file-name characters become `-`.
  - Load previous: `SkinPackagerHistory` in the app's preferences (`SkinPackagerHistory` key), one entry per name,
    newest first, at most 20; Shift while choosing deletes.
- Why: Windows-safe encodings and names; the Mac has no Windows plugin builds of its own, so the PE header is the
  reliable source.
- Skin impact: packages install with Deskset's installer (round-trip self-test); installation on a Windows desktop is
  not verified yet.
- Status: emulated

## Real packages tried (local only, not distributed)

All 15 packages of the local compatibility corpus install (re-checked by the review): 13 packager-made .rmskin files (Enigma, FluentDash11,
Nelamint, Simple Clean, Network Meter / HMNmeter2, Elegant Watch, eClock, Mini Weather, CPU meter, Core Loads, Easy
System Info, HDD Usage Bars, Simplistic Analog Clock) and 2 legacy Rainstaller packages that the previous installer
refused: **Mnml Drives** (Rainstaller.cfg at the top; its pixel font now renders from `@Resources/Fonts`) and
**PogPack 1.3** (Rainstaller.cfg inside a wrapper folder; root config `PogPack` so its `#SKINSPATH#PogPack\…` images
resolve, three fonts, the `Pog World` theme as a layout, a Windows add-on left out). Elegant Watch's font in
`<RootConfig>/Fonts`, eClock's and HDD Usage Bars' fonts lying next to their .ini files are now installed too (the
latter two checked by rendering). Each root folder of the corpus's Skins folder, zipped *with* the folder (as Finder's
"Compress" does) or chosen as a folder, installs under its original root config name — except `PogPack 1.3`, a raw
extraction of the legacy package, which is recognised as that package and installs as `PogPack` — and the one folder
holding no skin at all (`Mnml`, fonts only) is refused. Zipped *without* the folder (its contents at the top), every
folder with `@Resources` or top-level .ini files installs under the archive's name; `Mnml Drives` (config folders, no
`@Resources`) is split into `Mnml C` and `Mnml D` — the known limitation above.
