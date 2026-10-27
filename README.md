# Deskset

**Native desktop widgets for macOS — and it runs Rainmeter skins.**

[![CI](https://github.com/jokyme/Deskset/actions/workflows/ci.yml/badge.svg)](https://github.com/jokyme/Deskset/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jokyme/Deskset?include_prereleases&sort=semver)](https://github.com/jokyme/Deskset/releases)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey)
![Apple silicon and Intel](https://img.shields.io/badge/Mac-Apple%20silicon%20%7C%20Intel-lightgrey)

[中文说明](README.zh-CN.md) · [Changelog](CHANGELOG.md) · [Download (Apple silicon)](https://github.com/jokyme/Deskset/releases/download/v0.6.0/Deskset-0.6.0-arm64.dmg) · [Download (Intel)](https://github.com/jokyme/Deskset/releases/download/v0.6.0/Deskset-0.6.0-x86_64.dmg)

![Deskset's example skins in the dark and light themes](docs/images/example-skins.jpg)

Deskset puts live widgets on your Mac's desktop: clocks, calendars, weather, system monitors, network and disk meters,
audio visualizers, now-playing panels, to-do lists, timers, launchers and more. Use the bundled **Stationery** widget
collection, edit widgets in the Skin Studio, or install skins made for [Rainmeter](https://www.rainmeter.net) — the
large library of `.ini` / `.rmskin` skins from the Windows world — and run them on the Mac.

## Why "Deskset"

A *desk set* is the matched set of things on a writer's desk: a clock, a calendar, a pen stand, an inkwell. Small
objects you glance at while you work. Deskset brings that set to your Mac's desktop.

## Features

- **The Stationery widget collection.** Ships with a matched set of desktop widgets — clocks, calendars, weather, system
  monitors, music controls, vinyl turntable, audio spectrum, photos, notes, to-do lists, timers and folder launchers —
  with light and dark looks, multiple sizes, and English and Chinese labels.
- **Runs Rainmeter skins (including 5.0).** Double-click a `.rmskin` package, or open a `.zip` or skin folder with
  Deskset. Meters (including vector SVG graphics and interactive text inputs), measures, formulas, variables, bangs,
  mouse actions, file drag-and-drop, Lua scripts, and built-in plugins (AudioLevel, NowPlaying for Music and Spotify,
  WebParser, WiFiStatus, InputText, FileInfo, FolderInfo…) work natively on macOS.
- **Native and light.** Built natively for macOS with no web views. Each widget is a lightweight desktop panel that can
  sit on the desktop level, with normal windows, or always on top — with click-through, edge snapping, fading, and saved
  positions.
- **macOS styling and hardware sensors.** Widgets can use Liquid Glass on macOS 26 (frosted blur on earlier systems),
  SF Symbols icons, Apple system fonts, and colors that follow Light and Dark Mode, and can display your Mac's
  temperatures, fan speeds, power draw, and processor clocks (including automatic mapping for Windows CoreTemp, SpeedFan,
  and MSI Afterburner skins).
- **Weather and sun.** Built-in weather forecasts (current, hourly, and daily) powered by [MET Norway](https://api.met.no/),
  plus offline sunrise, sunset, and moon phase calculation. Search for any city offline, use your Mac's time zone city,
  or follow your current location.
- **Skin Studio.** A side-by-side live preview and code editor with syntax highlighting, diagnostics, and instant updates
  as you edit, plus one-click opening in your preferred external code editor.

## Requirements

- macOS 13 Ventura or later.
- Apple silicon or Intel — there is a separate download for each.
- Some skins ask for permissions: audio visualizers need System Audio Recording (macOS 14.2+; Screen Recording on
  13–14.1), now-playing skins need to control Music or Spotify, Wi-Fi skins need Location Services to read network
  names, and weather skins set to your current location need Location Services. macOS asks only when a loaded skin
  uses the feature.

## Install

1. Download the latest release (or see all versions on the [Releases](../../releases) page):
   - [**Deskset-0.6.0-arm64.dmg**](https://github.com/jokyme/Deskset/releases/download/v0.6.0/Deskset-0.6.0-arm64.dmg) ([`.zip`](https://github.com/jokyme/Deskset/releases/download/v0.6.0/Deskset-0.6.0-arm64.zip)) for Macs with Apple silicon (M1 and later),
   - [**Deskset-0.6.0-x86_64.dmg**](https://github.com/jokyme/Deskset/releases/download/v0.6.0/Deskset-0.6.0-x86_64.dmg) ([`.zip`](https://github.com/jokyme/Deskset/releases/download/v0.6.0/Deskset-0.6.0-x86_64.zip)) for Intel Macs.
2. Open the disk image and drag **Deskset** to **Applications**, then open it from Applications. You can also open
   Deskset in the disk image and choose **Install to Applications**. A first installation uses `~/Applications` if
   `/Applications` is not writable. If no installation prompt appears, use the drag-and-drop steps.

Deskset lives in the menu bar and has no Dock icon. If the menu bar icon is hidden (macOS lets you hide menu bar
items), open Deskset again from Applications to show the **Manage Skins** window.

### Updates and upgrading

Choose **Check for Updates…** in the Deskset menu or **Settings… ▸ General**. Deskset also checks for a new public
release once a day by default; turn this off in General settings if you prefer manual checks. Automatic checks stay
quiet when offline or when GitHub cannot be reached. **Close** dismisses the current notice; **Skip This Version**
stops automatic reminders for that version. A manual check still offers a skipped version.

Choose **Update** to download and verify the release for your Mac inside Deskset. When it is ready, choose
**Install and Relaunch** to save your edits, quit, replace the application, and reopen it, or **Later** to keep using
the current version. Cancelling an unsaved-edits prompt pauses installation. If downloading fails, you can retry or
use **Download Manually…** to open the release on GitHub. The application and its parent folder must be writable.
Downloads match your Mac: Apple silicon uses `arm64`, even when Deskset runs under Rosetta; Intel uses `x86_64`.

To upgrade manually, quit Deskset from its menu and save any edits, then open the new disk image. Drag Deskset to Applications
and choose **Replace**, or open the copy in the disk image and choose **Replace and Open**. The installer shows the
installed version, waits for you to quit any running copy, and refuses to replace a newer version with an older one.
If the existing application is not writable, use Finder to replace it. Open Deskset from Applications and eject the
disk image. Your skins and settings in `~/Library/Application Support/Deskset` are preserved.

## Using skins

- **Install:** double-click a `.rmskin` file, or use **Install Skin…** in the menu. Plain `.zip` archives and skin
  folders can be opened with Deskset too (Open With).
- **Manage:** **Manage Skins…** (⇧⌘,) lists every skin; load, unload, and change position, level and transparency.
- **Edit:** right-click a skin → **Edit Skin…** opens it in the Skin Studio. If you prefer your own code editor, choose
  it in **Settings… ▸ Editor**; the menu then also has **Edit in** that app. The files live in
  `~/Library/Application Support/Deskset/Skins` (**Open Skins Folder** in the menu).
- **Compatibility:** right-click a skin → **Compatibility Notes** lists what does not work as on Windows. Full details
  are in the [Compatibility Guide](docs/COMPATIBILITY.md).

Skins are programs: they can run Lua scripts, fetch web pages and run commands. Only install skins from sources you
trust (see [SECURITY.md](SECURITY.md)).

## Weather

Weather forecasts are **based on data from MET Norway** (the Norwegian Meteorological Institute,
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)); city names come from [GeoNames](https://www.geonames.org/)
(CC BY 4.0) and are looked up offline on your Mac. Every weather widget's right-click menu credits MET Norway and shows
when the data was updated.

- **Privacy:** only a weather widget running on the desktop makes requests. MET Norway receives your IP address and the
  place's coordinates rounded to about 1 km — nothing else. Using your current location asks for Location Services once;
  that location is rounded, kept in memory only, and never saved or logged. Using your Mac's time zone city asks for no
  permissions. Sun and moon times never use the network.
- **Turn it off:** `defaults write app.deskset.Deskset WeatherEnabled -bool NO` (undo with
  `defaults delete app.deskset.Deskset WeatherEnabled`).
- Skin author options and details: [docs/compat/weather.md](docs/compat/weather.md).

## Limitations

- Windows-only plugins (DLLs) and Windows programs that a skin launches cannot run on the Mac. The skin still loads,
  and its Compatibility Notes list what is missing.
- Hardware sensor readings (temperatures, fans, power, clocks) require no special permissions, but Apple does not
  document them: available readings vary by Mac model and are close approximations.
- Windows fonts are replaced by similar Mac fonts, so text can be a little wider or narrower.

## Troubleshooting

- **A skin shows zeros or no data:** open its Compatibility Notes. Audio, now-playing and Wi-Fi skins need a
  permission; if it was refused, allow Deskset in **System Settings → Privacy & Security**.
- **The menu bar icon is gone:** open Deskset again from Applications to show the Manage Skins window.
- **Anything else:** the log is at `~/Library/Logs/Deskset/Deskset.log`; please attach the relevant lines to an issue.

## Uninstall

Quit Deskset (menu bar → **Quit Deskset**) and move `Deskset.app` to the Trash. To remove your skins and settings as
well, delete `~/Library/Application Support/Deskset`, `~/Library/Caches/Deskset` and `~/Library/Logs/Deskset`, and
run `defaults delete app.deskset.Deskset`.

## Build from source

Requires Xcode 26 (Swift 6.2) or later:

```bash
bash scripts/build-app.sh
open build/Deskset.app
```

For development setup, tests, and architecture details, see [CONTRIBUTING.md](CONTRIBUTING.md).

To create the ZIP and styled drag-to-Applications DMG, add `--package`. Packaging also requires Python 3.10 or later;
the first run downloads the pinned tools in `scripts/dmg/requirements.txt` into `build/dmg-tools`. Later runs reuse
them. The Finder layout and Retina background are generated without a desktop session.

## Contributing

Contributions are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) first, especially the clean-room rule.

## License

Copyright © 2026 jokyme.

Deskset is free software under the [GNU General Public License v3](LICENSE). The example skins in `DefaultSkins` are
MIT-licensed, so you can base your own skins on them. Third-party code: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Deskset is an independent project and is not affiliated with or endorsed by Rainmeter. "Rainmeter" is a trademark of
its respective owners and is used only to describe compatibility. Deskset contains no Rainmeter code: it is a
clean-room implementation written from Rainmeter's public documentation.
