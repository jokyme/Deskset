# Deskset

**原生的 macOS 桌面小组件，而且能运行 Rainmeter 皮肤。**

[![CI](https://github.com/jokyme/Deskset/actions/workflows/ci.yml/badge.svg)](https://github.com/jokyme/Deskset/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jokyme/Deskset?include_prereleases&sort=semver)](https://github.com/jokyme/Deskset/releases)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey)
![Apple silicon and Intel](https://img.shields.io/badge/Mac-Apple%20silicon%20%7C%20Intel-lightgrey)

[English](README.md)

![Deskset 自带示例皮肤的深色与浅色主题](docs/images/example-skins.jpg)

Deskset 在 Mac 桌面上放置实时更新的小组件：时钟、日历、系统监控、网速和磁盘、音频可视化、正在播放……可以用自带的示例皮肤，
在 Skin Studio 里做自己的皮肤，也可以直接安装为 [Rainmeter](https://www.rainmeter.net) 制作的皮肤——Windows 世界里海量的
`.ini` / `.rmskin` 皮肤——在 Mac 上运行。

## 名字的由来

*Desk set* 指书桌上成套摆放的物件：时钟、日历、笔座、墨水瓶，都是工作时会随手瞥一眼的小东西。Deskset 把这一套搬到了 Mac
的桌面上。

## 功能

- **运行 Rainmeter 皮肤。** `@Include`、变量、公式、节变量、MeterStyle、Bang 与鼠标动作；全部 meter（含内联样式的 String、
  Image、Bar、Line、Histogram、Roundline、Rotator、Shape、Button、Bitmap）；各类 measure（CPU、内存、网络、磁盘、时间、
  开机时长、电池、Calc、WebParser……）；Lua 脚本；Rainmeter 自带插件为 macOS 原生重写（AudioLevel、接 Music / Spotify 的
  NowPlaying、WiFiStatus、InputText……）。双击 `.rmskin` 即可安装。
- **原生、轻量。** Swift + AppKit，Core Graphics 与 Core Text 绘制，不用网页视图。每个皮肤是桌面上的一个透明面板，可放在桌面层、
  普通层或置顶；支持点击穿透、贴边、淡入淡出和记住位置。
- **Skin Studio。** 可视化编辑器：画布、图层、组件库、属性面板，代码编辑器可以并排显示。修改会写回皮肤自己的文件，保留原有格式。
- **如实记录兼容性。** 所有与 Windows 表现不一致的地方都写在 [docs/COMPATIBILITY.zh-CN.md](docs/COMPATIBILITY.zh-CN.md)。
  用 390 个真实皮肤测试：没有崩溃，只剩 6 个皮肤有兼容性提示（都用了只有 Windows 版的插件 DLL）。

## 系统要求

- macOS 13 Ventura 或更新版本。
- Apple 芯片或 Intel 芯片，各有单独的安装包。
- 部分皮肤需要权限：音频可视化需要“系统音频录制”（macOS 14.2+；13–14.1 为“屏幕录制”），正在播放类皮肤需要控制 Music 或
  Spotify，Wi-Fi 皮肤需要定位服务才能读取网络名称。只有载入的皮肤用到时，macOS 才会询问。

## 安装

1. 在 [Releases](../../releases) 页面下载最新版本：
   - `Deskset-<版本>-arm64.dmg`：Apple 芯片（M1 及以后）的 Mac；
   - `Deskset-<版本>-x86_64.dmg`：Intel 芯片的 Mac。
2. 打开磁盘映像，把 **Deskset** 拖进「应用程序」。
3. Deskset 暂未经过 Apple 公证，第一次打开时 macOS 会提示无法验证。打开「系统设置 → 隐私与安全性」，向下滚动，点「仍要打开」。
   （也可以在终端执行 `xattr -dr com.apple.quarantine /Applications/Deskset.app`。）

Deskset 常驻菜单栏，没有 Dock 图标。如果菜单栏图标被隐藏了（macOS 允许隐藏菜单栏项目），从「应用程序」里再次打开 Deskset，
会弹出「Manage Skins」窗口。

## 使用皮肤

- **安装：** 双击 `.rmskin` 文件，或用菜单里的 **Install Skin…**。普通 `.zip` 压缩包和皮肤文件夹也可以用 Deskset 打开（打开方式）。
- **管理：** **Manage Skins…**（⇧⌘,）列出所有皮肤，可以载入、卸载，调整位置、层级和透明度。
- **编辑：** 右键皮肤 → **Edit Skin…**，在 Skin Studio 里打开。想用自己的代码编辑器，在 **Settings… ▸ Editor** 里选择，
  右键菜单会多出 **Edit in** 该 App。皮肤文件放在 `~/Library/Application Support/Deskset/Skins`（菜单里的 **Open Skins Folder**）。
- **兼容性：** 右键皮肤 → **Compatibility Notes** 列出与 Windows 不同的地方。

皮肤本质上是程序：可以运行 Lua 脚本、抓取网页、执行命令。只安装来源可信的皮肤（见 [SECURITY.md](SECURITY.md)）。

## 已知限制

- 只有 Windows 版的插件（DLL）和皮肤要启动的 Windows 程序无法在 Mac 上运行。皮肤照样能载入，Compatibility Notes 会列出缺了什么。
- 暂不支持硬件传感器（温度、风扇转速）。
- Windows 字体会换成相近的 Mac 字体，文字宽度可能略有差别。
- Deskset 暂未经过 Apple 公证（见「安装」）。

## 常见问题

- **皮肤显示 0 或没有数据：** 先看它的 Compatibility Notes。音频、正在播放、Wi-Fi 类皮肤需要权限；如果之前拒绝了，到「系统设置 → 隐私与安全性」里允许 Deskset。
- **菜单栏图标不见了：** 从「应用程序」里再次打开 Deskset，会弹出 Manage Skins 窗口。
- **其他问题：** 日志在 `~/Library/Logs/Deskset/Deskset.log`，提 issue 时请附上相关的几行。

## 卸载

退出 Deskset（菜单栏 → **Quit Deskset**），把 `Deskset.app` 移到废纸篓。如果要连皮肤和设置一起删除，再删掉
`~/Library/Application Support/Deskset`、`~/Library/Caches/Deskset`、`~/Library/Logs/Deskset`，并执行
`defaults delete app.deskset.Deskset`。

## 从源码构建

需要 Xcode 26（Swift 6.2）或更新版本。

```bash
swift build                         # 调试构建
swift run DesksetSelfTest           # 引擎自测
.build/debug/Deskset --self-test    # App 自测
bash scripts/build-app.sh           # 为本机架构生成 build/Deskset.app
open build/Deskset.app
```

生成两种架构的安装包：

```bash
bash scripts/build-app.sh --arch arm64 --package    # dist/Deskset-<版本>-arm64.dmg 和 .zip
bash scripts/build-app.sh --arch x86_64 --package   # dist/Deskset-<版本>-x86_64.dmg 和 .zip
```

推送 `v0.1.0` 这样的标签，GitHub Actions 会构建两种架构并创建一个 Release 草稿（见
[.github/workflows/release.yml](.github/workflows/release.yml)）。

## 参与贡献

欢迎贡献，请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，尤其是其中的 clean-room 规则。

## 许可证

Copyright © 2026 jokyme.

Deskset 是自由软件，采用 [GNU 通用公共许可证 v3](LICENSE)。`DefaultSkins` 里的示例皮肤采用 MIT 许可，可以在它们的基础上制作
自己的皮肤。第三方代码见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Deskset 是独立项目，与 Rainmeter 没有关联，也未获其认可。“Rainmeter”是其所有者的商标，这里仅用于说明兼容性。Deskset
不包含任何 Rainmeter 代码，是依据 Rainmeter 公开文档独立实现的（clean-room）。
