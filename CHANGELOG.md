# Changelog

[简体中文](CHANGELOG.zh-CN.md)

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
