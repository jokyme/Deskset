# Changelog

[简体中文](CHANGELOG.zh-CN.md)

## 0.3.0

This release adds saved desktop layouts, updates you can download and install inside Deskset, and a clearer installation experience.

### Added

- **Saved desktop layouts.** Save, load, edit and delete layouts from Manage, or load one from the menu bar. Save an empty layout, exclude unloaded skins, or include your wallpaper. Loading a normal layout saves the previous configuration as `@Backup`.
- **Layout commands and package support.** Load layouts with `!LoadLayout`, open the Layouts tab with `!Manage Layouts`, or apply a layout included in a skin package during installation.
- **Updates inside Deskset.** Check from the menu or General settings, with automatic daily checks enabled by default. Choose **Update** to download and verify the correct version for your Mac, then **Install and Relaunch** when ready. Deskset prompts you to save open edits before restarting. Choose **Later** to postpone installation or **Skip This Version** to stop automatic reminders for that release.

### Changed and improved

- **Clearer native dialogs.** Update and installation windows now show progress, version details and readable error messages, with light and dark appearances and keyboard-accessible controls.
- **A styled disk image and guided installation.** The disk image includes a custom background, a drag-to-Applications arrow, and English and Chinese instructions. Open Deskset from the disk image to install or replace it; the installer verifies the copied app, prevents downgrades and keeps the previous copy available for recovery if replacement fails.
- **More complete layout restoration.** Layouts retain skin settings, saved positions and anchors, and support Rainmeter 5.0 `Zoom` values from 10–500%. Layout replacement waits for skin close actions before loading the new desktop.

### Fixed

- Fixed the disk-image installer remaining on its progress window after copying the application, preventing the installed copy from opening.
- Fixed player controls and audio spectrum recovery after quitting and reopening Music.

### Upgrading

- To upgrade from 0.2.0 or 0.2.1, download this release's DMG or ZIP and replace the application. In-app installation is available after upgrading.
- Your skins, saved layouts and settings are preserved. Save open edits and quit Deskset before replacing it manually.

[Full changelog](https://github.com/jokyme/Deskset/compare/v0.2.0...v0.3.0)

## 0.2.1

This release adds update checks, a clearer installation experience, and fixes for music widgets after Music restarts.

### Added

- **Update checks and notifications.** Check for updates from the Deskset menu or General settings. Deskset checks daily by default and automatically prompts once for each newer version; automatic checks can be turned off. **View Update** opens the GitHub release page to download the version for your Mac. Updates are not downloaded or installed automatically.

### Changed and improved

- **A styled disk image.** The installer now has a custom background, a drag-to-Applications arrow, and English and Chinese installation instructions.
- **Guided installation and replacement.** Open Deskset from the disk image to install it or replace an existing copy. The installer verifies the copied app's signature, prevents downgrades, asks you to quit running copies, and keeps the previous application available for recovery if replacement fails.

### Fixed

- Fixed player controls and audio spectrum recovery after quitting and reopening Music.

### Upgrading

- Quit Deskset and save any edits before replacing the application. Your skins, settings and desktop layout are preserved.
- Still supports macOS 13 and later on Apple silicon and Intel Macs.

[Full changelog](https://github.com/jokyme/Deskset/compare/v0.2.0...v0.2.1)

## 0.2.0

This release brings a new collection of desktop widgets, a simpler code-and-preview layout, and support for more Rainmeter skins.

### Added

- **The new Stationery widget collection.** Arrange your desktop with clocks, calendars, weather, system monitors, music controls, audio visualizers, photos, to-do lists, timers, launchers and more. Choose light or dark looks and English or Chinese labels, with multiple sizes for many widgets.
- **Weather and sun times.** See forecasts for a city, your Mac's time zone or your current location, along with sunrise, sunset and moon phases. Using your current location requires location permission.
- **More Mac hardware readings.** See temperatures, fan speeds, power use and more on your desktop. Available readings vary by Mac model and are approximate.
- **More macOS styling options.** Widgets can use system icons, fonts and colors that follow light and dark mode, plus Liquid Glass on macOS 26. Earlier systems use a frosted blur effect.

### Changed and improved

- **A simpler Skin Studio.** Code and live preview now sit side by side, making it easier to check changes as you edit. The previous visual editing interface, including canvas dragging, the layer list, component library and property inspector, has been removed. The editor interface is currently in English.
- **Broader Rainmeter compatibility.** Added support for more Rainmeter 5.0 features, including vector graphics, text input and file drag and drop. Some features still differ; see the [compatibility guide](docs/COMPATIBILITY.md).
- **Clearer permission messages.** Music and audio widgets distinguish missing access from an idle player, making it easier to understand why no data appears.

### Fixed

- Improved text encoding detection for older skins, reducing garbled Chinese and other text.
- Fixed the Turntable widget keeping an old title, artist or cover after the track changes.
- Improved audio visualizer recovery when sound returns. The spectrum strip stays visible while quiet unless Hide When Idle is enabled.
- Fixed stability issues when unloading and closing skins.

### Upgrading

- Still supports macOS 13 and later on Apple silicon and Intel Macs.
- Stationery is the new default widget collection. Upgrading from 0.1.0 preserves the original Deskset example skins and your desktop layout. Load the new widgets from Manage Skins.
- Windows-only plugins and programs still cannot run directly on macOS.

[Full changelog](https://github.com/jokyme/Deskset/compare/v0.1.0...v0.2.0)
