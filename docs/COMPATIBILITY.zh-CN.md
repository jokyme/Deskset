# Deskset 兼容性指南：Rainmeter 皮肤在 Mac 上的表现

Deskset 在 macOS 上原生运行 Rainmeter 皮肤（`.ini`、`.rmskin`）。大多数皮肤无需修改即可使用，但 Mac 毕竟不是
Windows。本文档列出了**皮肤在 Deskset 上与在 Windows 版 Rainmeter 上表现不同的每一处地方**，说明原因，以及皮肤作者或
用户可以怎么应对。

本文档由 [`docs/compat/`](compat/) 中各领域的说明（引擎、Lua、插件、音频、媒体与界面、安装器、App）以及对 15 个真实
皮肤包的重新测试（见[真实皮肤测试结果](#12-真实皮肤测试结果)）汇编而成。所有内容都基于公开的 Rainmeter 手册
（<https://docs.rainmeter.net/manual/>）、公开的插件 README 以及对皮肤实际表现的观察。Deskset 是独立的净室实现，不包含
任何 Rainmeter 代码。本文档描述的是 2026-09-24 时的 Deskset。

**目录**

1. [如何阅读本文档](#1-如何阅读本文档)
2. [支持情况一览](#2-支持情况一览)
3. [最容易注意到的差异](#3-最容易注意到的差异)
4. [macOS 权限](#4-macos-权限)
5. [插件支持矩阵](#5-插件支持矩阵)
6. [引擎：皮肤、meter、measure 与绘制](#6-引擎皮肤metermeasure-与绘制)
7. [App、窗口与 bang](#7-app窗口与-bang)
8. [Lua 脚本](#8-lua-脚本)
9. [内置插件（核心）](#9-内置插件核心)
10. [音频、媒体、网络与界面插件](#10-音频媒体网络与界面插件)
11. [WebParser 与皮肤安装器](#11-webparser-与皮肤安装器)
12. [真实皮肤测试结果](#12-真实皮肤测试结果)
13. [已知缺口与计划](#13-已知缺口与计划)
14. [资料来源与方法](#14-资料来源与方法)

本文档的英文版见 [`COMPATIBILITY.md`](COMPATIBILITY.md)。选项名、bang 等技术标识符保留英文原文。

---

## 1. 如何阅读本文档

每个条目都由相同的五部分组成：

- **Windows** —— Rainmeter 的行为，以手册的描述为准（或以已知可正常运行的皮肤中观察到的行为为准）。
- **Mac** —— Deskset 的行为。
- **原因** —— 造成差异的 macOS 限制、缺失的 API、权限或取舍判断。
- **对皮肤的影响** —— 你会注意到什么，以及可用的变通办法。
- **状态** —— 取以下之一：

| 状态 | 含义 |
| --- | --- |
| **完全一致**（identical） | 与手册描述一致。Deskset 还可能接受少数 Rainmeter 会拒绝的写法（“宽松处理”）。 |
| **模拟实现**（emulated） | 目的和选项相同，但基于 macOS 的对应机制重新实现。数值、措辞或时机在细节上可能不同。 |
| **部分支持**（partial） | 部分选项或数值可用；条目中会写明哪些不可用。 |
| **不支持**（not supported） | 不起作用。数值为 `0` / 空，皮肤的 *兼容性提示*（菜单和管理窗口中）会说明这一点。皮肤不会因此崩溃。 |
| **仅 Mac**（Mac-only） | Deskset 特有的安全限制或界面功能，Rainmeter 中没有对应项。 |

“取舍判断”表示手册没有规定、Deskset 必须自行选择行为的地方。

凡是作为证据点名的皮肤，都是仅在本地测试过的第三方皮肤；Deskset 不附带任何第三方皮肤。

---

## 2. 支持情况一览

| 领域 | 总体 | 可用的部分 | 不可用（或差异最大）的部分 |
| --- | --- | --- | --- |
| 皮肤文件、变量、公式、bang | 完全一致 | INI 规则、`@Include`、`#Var#` / 节变量、公式、`!SetOption` 及其他皮肤 bang | 冷门的 PCRE 正则特性；普通选项中的 Windows 环境变量（`%APPDATA%`） |
| 布局与文字 | 模拟实现 | `r`/`R` 定位、StringAlign、窗口尺寸、内联选项、`@Resources\Fonts` 中的字体 | 微软字体会被替换；文字宽度可能相差一两个像素 |
| Meter（String、Image、Bar、Bitmap、Button、Line、Histogram、Roundline、Rotator、Shape） | 模拟实现 | 手册中的所有 meter 类型与选项 | Histogram 的 `PrimaryImageRotate` / ColorMatrix 选项 |
| 系统 measure（CPU、内存、网络、磁盘、时间、开机时长、SysInfo、Process、电池） | 模拟实现 | 全部可用，映射到 macOS 数据 | 所有盘符都指启动磁盘；Windows 网卡名会回退到当前活动接口 |
| 注册表 | 模拟实现（固定集合） | Windows 版本、CPU / GPU 名称、核心数、用户文件夹、壁纸 | 其他所有注册表值均为 `0` / 空 |
| Lua（`Measure=Script`、内联 Lua） | 完全一致 | Lua 5.1 以及完整的 SKIN / SELF / Measure / Meter API | `os.execute` 只能打开文件和网址；移除了少数不安全的函数 |
| Rainmeter 自带插件 | 模拟实现 | 除两个以外全部实现（其中 7 个部分支持）：ActionTimer、AudioLevel、NowPlaying、InputText、RunCommand、UsageMonitor…… | WindowMessage 和 VirtualDesktops 在 macOS 上没有对应物；温度 / 风扇读数为 0（没有公开的传感器 API） |
| 常用第三方插件 | 9 个模拟或部分支持 | WebNowPlaying、FrostedGlass、Chameleon、IsFullScreen、GetActiveTitle、SysColor、AppVolume、Mouse、Slider | 其他任何 Windows DLL（PowershellRM、ActiveNet、MSI Afterburner、HWiNFO……） |
| 安装器 | 模拟实现 | `.rmskin`、旧版 Rainstaller 包、普通 ZIP、已解压的文件夹、内含 `.rmskin` 的下载 ZIP；字体 | `.rar` / `.7z`；Windows 插件和附加程序从不安装；布局（layout）会安装但暂不能应用 |
| 窗口与窗口设置 | 模拟实现 | 拖动、贴边、点击穿透、透明度、淡入淡出、所有位置类 bang | 窗口层级是 macOS 的层级；用 ⌘ 代替 Ctrl；没有 DragGroup、Aero 模糊和保存的锚点；暂不能加载布局 |

---

## 3. 最容易注意到的差异

1. **温度、风扇转速、电压和 GPU 频率读数为 0。** macOS 没有读取硬件传感器的公开 API（CoreTemp、SpeedFan、HWiNFO、
   MSI Afterburner 的数值都受影响）。CPU 名称和各核心负载可以正常显示。
2. **盘符（`C:`、`D:`……）都显示启动磁盘。** 其他卷请写 `Drive=/Volumes/卷名`。
3. **Windows 专属的插件 DLL 不起作用**，除非 Deskset 重新实现了它（见[插件矩阵](#5-插件支持矩阵)）。皮肤中依赖它的部分
   保持空白，但皮肤本身照常运行。
4. **音乐皮肤显示的是 Music.app 或 Spotify**，无论皮肤原本是为哪个播放器写的（WMP、foobar2000、AIMP、iTunes……），
   而且显示正在播放的那一个。
5. **macOS 会请求权限**：皮肤第一次需要系统音频、麦克风、播放器、Wi-Fi 名称或受保护的文件夹时
   （[权限表](#4-macos-权限)）。
6. **字体：** 微软字体（Segoe UI、Calibri、Consolas……）会被替换为相近的 Mac 字体，文字可能略宽或略窄。放在皮肤
   `@Resources\Fonts` 中的字体与 Windows 上完全一样可用；安装器还会把皮肤包放在其他位置的字体装好（Windows 用户需要
   手动完成这一步）。
7. **启动 Windows 程序的命令**（`.exe`、PowerShell、`cmd` 内置命令、`wmic`）不会执行。通用的和 Mac 的命令行（`curl`、
   `date`、`open`）可以在 RunCommand 中使用；网址和文件照常打开。
8. **皮肤窗口默认位于桌面层**（即 Rainmeter 的 “On Desktop” 层级），并使用 macOS 的窗口层级。
9. **老皮肤可以直接安装：** Rainmeter 4 会拒绝的旧版 Rainstaller 包和普通 ZIP 都能安装，其中附带的字体也会装进皮肤。
10. **布局会被安装，但暂时不能应用**，所以依靠布局自动排列的套件目前需要逐个加载皮肤。
11. **⌘ 代替 Ctrl**：按住 ⌘ 拖动可以移动任何皮肤，Control-点按（Mac 的右键）会打开皮肤菜单。

---

## 4. macOS 权限

只有当 *App 中已加载的皮肤* 真正需要时才会请求权限。预览、`--render` 以及管理窗口的兼容性检查从不触发权限弹窗。
Deskset 从不主动请求“辅助功能”权限（只在你已经授予时才使用），只有在 macOS 13 – 14.1 上运行音频频谱皮肤时才会请求“屏幕录制”权限。

| 功能（皮肤选项） | macOS 权限 | 何时请求 | 如果拒绝 |
| --- | --- | --- | --- |
| AudioLevel `Port=Output`（可视化频谱），macOS 14.2 及以上 | 系统录音（“屏幕与系统录音” → “仅系统录音”） | 频谱类皮肤第一次运行时 | macOS 只提供静音：电平读数为 0，`DeviceStatus` 仍为 1。如果其他 App 正在播放声音而频谱皮肤约 10 秒都没有声音，皮肤会得到一条指向该权限的兼容性提示 |
| AudioLevel `Port=Output`，macOS 13 – 14.1 | 屏幕录制，授权后需重启 Deskset | 频谱类皮肤第一次运行时 | 电平为 0，`DeviceStatus` 为 0，记录一行日志 |
| AudioLevel `Port=Input` | 麦克风（采集时显示橙色指示点） | 输入电平类皮肤第一次运行时 | 电平为 0，`DeviceStatus` 为 0，记录一行日志。每 10 秒重试一次，之后再授权无需重启 |
| AppVolume `NumberType=Peak`、AppVolume 静音 | 系统录音 | 第一次使用峰值 / 静音时 | 峰值为 0；静音无效 |
| NowPlaying、iTunes、WebNowPlaying 的数据与命令；未授予辅助功能时 MediaKey 的切歌键 | 自动化 → Music / Spotify | 第一次轮询*正在运行*的播放器，或第一次向它发送命令时 | 播放器显示为已关闭；命令不起作用。每 30 秒重新检查一次，之后再授权无需重启 |
| WiFiStatus `SSID`、`LIST` | 定位服务（macOS 只把 Wi-Fi 名称提供给这类 App） | 第一次加载含 SSID / LIST measure 的皮肤时 | SSID 和网络列表为空；信号质量、速率、加密方式仍可用 |
| RecycleManager `EmptyBin` / `EmptyBinSilent`、FileView `Properties` | 自动化 → 访达 | 第一次使用时 | 不清空废纸篓 / 不打开“显示简介”窗口 |
| RecycleManager `RecycleType=Size` | 完全磁盘访问权限（没有弹窗；需在“系统设置 → 隐私与安全性”中手动开启） | — | 大小读数为 0；兼容性提示和日志会说明在哪里授权。`Count` 不需要权限 |
| 皮肤使用桌面、文稿、下载、可移除卷或网络卷中的任何文件（Quote、FolderInfo、FileView、Lua `io`、图片以及皮肤指定的其他文件） | 文件与文件夹 | 第一次访问该文件夹时 | 数值为空、图片不显示；Lua 的 `io.open` 返回 nil 和错误信息 |
| 以真实媒体键事件发送 MediaKey（音量 HUD、任意播放器） | 辅助功能（从不主动请求） | — | 切歌键通过自动化发给 Music / Spotify；音量键直接修改音量（不显示 HUD） |
| GetActiveTitle 读取窗口标题 | 辅助功能或屏幕录制（从不主动请求） | — | 显示最前面 App 的名称，而不是窗口标题 |
| WebParser 或 Ping 访问本地网络中的设备 | 本地网络 | 第一次发出这类请求时 | 请求失败 |

Win7Audio（音量、静音、输出设备）、SysColor、IsFullScreen、Chameleon、CPU / 内存 / 网络 / 磁盘 measure 以及 Slider 对屏幕上
任何位置点击的响应（只观察鼠标事件，从不观察按键）都不需要任何权限。被拒绝的权限（麦克风、屏幕录制、系统录音、定位、自动化、读取废纸篓大小所需的完全磁盘访问权限）以及在没有辅助功能权限时
发送的 MediaKey 切歌键，也会出现在皮肤的 *兼容性提示* 中，让用户知道皮肤为什么是空的、该去哪里修复。这类提示在不再适用时会
自动消失：之后授予了权限（Deskset 会在 30 秒内察觉；macOS 13 – 14.1 上的屏幕录制权限，以及系统设置提示“退出并重新打开”
Deskset 时的完全磁盘访问权限，要在重启之后才生效），或者对于“频谱没有声音”的提示，一旦有声音传来就会消失。

---

## 5. 插件支持矩阵

`Plugin=Name`、`Name.dll` 和 `Plugins\Name.dll` 都可以，大小写不限。“以前是插件”的 measure（SysInfo、Process、
WebParser、RecycleManager、MediaKey、NowPlaying、WiFiStatus）两种写法都能用。本矩阵涵盖手册“插件”页列出的所有插件（包括
已弃用的插件），以及 15 个受测皮肤包中出现的所有 `Plugin=` 值。

### Rainmeter 自带的插件及插件式 measure

| 插件 / measure | 状态 | 说明 |
| --- | --- | --- |
| ActionTimer | 完全一致 | 动作列表、Wait、Repeat、Execute、Stop；在主运行循环上无漂移计时 |
| AdvancedCPU（已弃用） | 模拟实现 | 按 Windows 的 100 ns 单位给出各进程 CPU 时间；其他用户的进程合并为一个名为 `System` 的进程 |
| AudioLevel | 模拟实现 | Core Audio 进程 tap（系统音频）或输入设备；RMS、Peak、FFT、Bands；需要权限 |
| CoreTemp | 部分支持 | `Load`（各核心 CPU）和 `CpuName` 可用；温度、TjMax、电压、功率为 0；Apple 芯片上 CPU 频率为 0 |
| FileView | 部分支持 | 类似访达的列表和图标；`ContextMenu` 只能在访达中显示该项目 |
| FolderInfo | 模拟实现 | 后台扫描；使用 Mac 的隐藏 / 系统文件规则 |
| InputText | 模拟实现 | 非激活面板中的原生文本框；在 Stay Topmost 皮肤上也能用 |
| iTunes（已弃用的 `iTunesPlugin`） | 完全一致 | 读取并控制 Music.app（或 Spotify） |
| MediaKey | 模拟实现 | 有辅助功能权限时发送真实媒体键；否则改为播放器命令和直接修改音量；`Stop` 发给播放器 |
| NowPlaying | 模拟实现 | 所有 `PlayerName` 都对应 Music.app 和 Spotify；“谁在播放就显示谁”规则 |
| PerfMon（已弃用） | 部分支持 | 常用计数器映射到 Darwin 数据；其余为 0 |
| Ping（`PingPlugin`） | 完全一致 | 在后台线程上发送无需特权的 ICMP echo |
| PowerPlugin | 模拟实现 | 电池状态；没有电池的 Mac 上 `Percent` 为 100、`ACLine` 为 1；Apple 芯片上 `Hz` / `MHz` 为 0 |
| Process | 模拟实现 | Mac 进程名（ProcessName 中的 `.exe` 会被去掉） |
| QuotePlugin | 完全一致 | 随机取文件中的一行或文件夹中的一个文件；Windows 路径映射到 Mac 文件夹 |
| RecycleManager | 部分支持 | 废纸篓：`Count` 可用；`Size` 需要完全磁盘访问权限；清空通过访达完成 |
| Registry（measure） | 模拟实现 | 一组固定的机器信息用 macOS 数据回答；其余为 0 / 空 |
| ResMon | 部分支持 | `Handle` = 打开的文件描述符数；GDI / USER / Window 为 0 |
| RunCommand | 部分支持 | 通过 `/bin/sh` 运行；Windows 专属命令行在启动前就以错误 103 失败 |
| Script（Lua） | 完全一致 | Lua 5.1.5，完整 SKIN API；见 [§8](#8-lua-脚本) |
| SpeedFan | 部分支持 | 在支持硬件传感器之前读数为 0 |
| SysInfo | 模拟实现 | 系统、用户、屏幕、网卡都有 Mac 的对应值；少数 Windows 专属类型为 0 / 空 |
| UsageMonitor | 部分支持 | 进程的 CPU、内存、IO，各核心负载，内存、分页、网络、磁盘；GPU 和冷门计数器为 0 |
| VirtualDesktops（旧版 Rainmeter；当前手册中没有） | 不支持 | 只报告一个桌面；命令被忽略（macOS 的“空间”没有公开 API） |
| WebParser | 完全一致 | PCRE 正则转换为 ICU；见 [§11](#11-webparser-与皮肤安装器) |
| WiFiStatus | 模拟实现 | CoreWLAN；SSID / LIST 需要定位服务；RXRate 等于 TXRate |
| Win7AudioPlugin | 模拟实现 | 默认输出设备的音量、静音、切换设备；无需权限 |
| WindowMessage | 不支持 | macOS 没有窗口消息；数值为 0，命令被忽略 |

### 常用第三方插件

| 插件 | 状态 | 说明 |
| --- | --- | --- |
| AppVolume | 部分支持 | App 列表和峰值（macOS 14.2 及以上）；通过静音 tap 实现单个 App 静音；macOS 上无法修改单个 App 的音量 |
| Chameleon | 模拟实现 | 用 Deskset 自己的聚类方法从壁纸或图片中取色（思路相似，结果不完全相同） |
| FrostedGlass | 模拟实现 | 在皮肤后面使用 macOS 的毛玻璃效果（NSVisualEffectView）；在 `--render` 生成的图片中看不到 |
| GetActiveTitle | 部分支持 | 只有在授予辅助功能 / 屏幕录制权限时才读取窗口标题，否则返回 App 名称 |
| IsFullScreen | 部分支持 | 全屏检测可用；进程名是 Mac 的 App 名称（`Safari`），不会是 `chrome.exe` |
| Mouse | 模拟实现 | 在皮肤的任意位置响应鼠标（拖动滑块）；在皮肤上按下后一直跟随到松开，指针移出皮肤也一样；RequireDragging 的 Start / Stop；见 §9.8 |
| Slider（Mouse 插件的第 2 版） | 模拟实现 | 左键、右键或中键的 ClickAction、DragAction、HoldAction、ReleaseAction 和 MoveAction，在皮肤上和屏幕上任何其他位置都响应（不需要权限）；见 §9.9 |
| SysColor | 模拟实现 | Windows 的系统颜色映射到 macOS 的语义颜色（强调色、高亮、窗口、文字……） |
| WebNowPlaying | 部分支持 | 显示 Music / Spotify；不支持浏览器扩展（网页播放器） |
| 其他任何 Windows 插件 DLL（例如 PowershellRM、ActiveNet、MSI Afterburner、HWiNFO） | 不支持 | 数值为 0 / 空，显示一条兼容性提示，皮肤其余部分照常工作 |

安装器会列出皮肤包中包含的 DLL，并提醒使用不受支持插件的皮肤会缺少相应数值。

---

## 6. 引擎：皮肤、meter、measure 与绘制

简而言之：皮肤文件、变量、公式和 bang 都遵循手册。布局与 Windows 100 % 缩放时一致。差异来自 macOS 本身（用点而不是
像素、字体不同、没有盘符、没有注册表），以及手册未作规定时的取舍判断。详细说明：[`compat/engine.md`](compat/engine.md)。

### 6.1 布局与窗口尺寸

#### 坐标与单位
- **Windows：** X、Y、W、H 和字号都是 96 DPI 下的屏幕像素。
- **Mac：** 皮肤中的一个像素就是 macOS 的一个点（point）。在 Retina 屏幕上一切都以 2× 绘制（更清晰，布局不变）。
  `#SCREENAREAWIDTH#`、`#WORKAREA…#` 和 SysInfo 的屏幕数值也以点为单位。
- **原因：** macOS 以点为单位布局窗口；这样皮肤的物理大小与在典型 Windows 桌面上相同。
- **对皮肤的影响：** 布局一致。位图按每个点一个图像像素显示，因此低分辨率图片看起来与 100 % 缩放的 Windows 屏幕上一样
  略显模糊。
- **状态：** 模拟实现

#### 对齐的 String 和 Bitmap meter 之后的相对位置（`r` / `R`）
- **Windows：** `r` 相对于上一个 meter 的上 / 左边缘，`R` 相对于其下 / 右边缘；StringAlign “始终以 X 或 Y 的值为准”。
  正常运行的皮肤（eClock 的长阴影、EasyInfo 的 LED 数字、FluentDash11 的设置行）表明，下一个 meter 是从对齐 meter 的
  *锚点*（即它的 X / Y 选项）开始定位的。
- **Mac：** 相同。`[Meter:X]` / `[Meter:Y]` 仍然返回移动后的（“实际”）位置，与手册“节变量”页的说法一致。BitmapAlign
  采用同样的规则（取舍判断）。隐藏的 meter 没有尺寸，也从不移动。
- **原因：** 手册的锚点规则加上作者的截图。
- **对皮肤的影响：** 右对齐、居中对齐的堆叠、阴影以及“标签 / 数值”行与 Windows 上一样对齐。
- **状态：** 完全一致

#### 窗口尺寸何时计算
- **Windows：** `DynamicWindowSize=1` 时每次更新都调整窗口大小；否则在皮肤加载时确定大小。
- **Mac：** 没有 DynamicWindowSize 时，在第一次更新结束时根据所有可见 meter（Container 的内容 meter 不计入）和
  `BackgroundMode=0` 的背景图计算一次大小。第一次更新期间由 measure 触发的 `!Redraw` 不会提前确定窗口大小。
  `SkinWidth` / `SkinHeight` 会覆盖计算结果。
- **原因：** 按手册。
- **对皮肤的影响：** 如果皮肤的文字在加载后变长，而又既没有 DynamicWindowSize 也没有固定的 `W`，就会被截断——与 Rainmeter
  完全相同。例如加载时显示 “CPU: 8%”，之后显示 “CPU: 21%”。请加上 `DynamicWindowSize=1` 或 `W`。
- **状态：** 完全一致

#### 第一次更新之前的 meter 几何信息
- **Windows：** 没有写明。Lua 主代码块在“皮肤的初始化阶段”运行，Initialize() 在“第一次更新周期中”运行；`Meter:GetX()` /
  `GetW()` 是 meter 的实际位置和尺寸。
- **Mac：** meter 在第一次更新结束时完成布局。在此之前询问 meter 位置或尺寸的任何东西——脚本的主代码块、Initialize() 或第一次
  Update()（`GetX`、`GetW`、`SetX`……），或者第一次更新中由 measure 读取的 `[Meter:X]` / `[Meter:W]`——会先得到一个根据
  meter 选项计算的临时布局（带 `r` / `R` 的 X / Y、W / H、Padding、Hidden、Container、图片和形状尺寸，以及 String meter 用
  当时绑定 measure 的值组成的文字）。临时布局从不确定窗口大小。
- **原因：** 取舍判断——手册没有说明 meter 何时有几何信息；选项在加载时就已知，据此计算的布局是最有意义的近似值（以前在第一次
  更新结束前所有数值都是 0）。
- **对皮肤的影响：** 在 Initialize() 中保存 meter 位置或尺寸的脚本会得到根据选项计算的值；绑定 measure 的 String meter 只有在
  第一次更新之后才有真实宽度。
- **状态：** 模拟实现

#### 背景图尺寸（`BackgroundMode=0`）
- **Windows：** “所有通用图像选项都适用于 Background”；模式 0 按图片原尺寸显示。
- **Mac：** 窗口至少与经过 ImageCrop / ImageRotate（以及 `UseExifOrientation=1` 时的 EXIF 方向）处理后的图片一样大。
  取舍判断：只设置了 `Background=` 而没有设置 `BackgroundMode` 的皮肤按模式 0 处理（手册默认值 1 会让该选项毫无作用）。
- **原因：** 窗口必须能容纳绘制的内容。
- **对皮肤的影响：** 无。
- **状态：** 完全一致（外加一处取舍判断）

#### Container
- **Windows：** 内容被容器裁剪；容器不能嵌套。
- **Mac：** 相同。`[ContentMeter:X]` 使用皮肤坐标（取舍判断）。无效的 `Container=` 只记录日志，不作为兼容性提示。
- **原因：** 按手册。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

### 6.2 文字与字体

#### 字号
- **Windows：** `FontSize` 是 96 DPI 下的磅值。
- **Mac：** 实际点数 = FontSize × 96 / 72（FontSize=10 绘制为 13.33 点的文字），因此文字所占空间与 Windows 100 % 缩放时
  相同。
- **原因：** macOS 每英寸 72 点；Rainmeter 的尺寸以 96 DPI 为前提。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 字体替换
- **Windows：** FontFace 指定已安装的字体家族；找不到时使用 Arial。
- **Mac：** 先找已安装或由皮肤注册的字体家族；再查一张 macOS 未自带的微软字体对照表：Segoe UI（及其各字重）→ 系统字体
  （沿用 Segoe UI 的行高参数）、Calibri → 系统字体、Consolas / Lucida Console → Menlo、Cambria / Constantia →
  Georgia、Tahoma → Verdana、Century Gothic → Futura、Bahnschrift → DIN Alternate、Microsoft YaHei（微软雅黑）→
  PingFang SC（苹方）、Meiryo / Yu Gothic → Hiragino Sans（冬青黑体）、Malgun Gothic → Apple SD Gothic Neo……；然后按
  完整名 / PostScript 名（“Fira Sans Bold”）以及带样式词的名称（“Roboto Light Italic”）查找；最后使用 Arial。Marlett
  中表示窗口控制按钮的字母映射为 Unicode 符号。Segoe MDL2 Assets / Segoe Fluent Icons 的图标字形在 Mac 上没有对应物。
- **原因：** 这些字体属于微软，Mac 上没有。只复制了 Segoe UI 的行高参数。
- **对皮肤的影响：** 文字可能略宽或略窄，`ClipString` 截断的位置可能不同。来自 Windows 的图标字体显示为空方框。把字体
  放进 `@Resources\Fonts` 即可得到完全相同的文字。
- **状态：** 模拟实现（Windows 图标字体：不支持）

#### 皮肤字体（`@Resources\Fonts`、`LocalFont`）
- **Windows：** 根配置 `@Resources\Fonts` 中的字体“会自动加载”；`LocalFontN=` 可加载更多字体。皮肤包中其他位置的字体
  需要用户自行安装。
- **Mac：** 同样的文件（`.ttf`、`.otf`、`.ttc`、`.otc`）会在皮肤测量任何文字之前只为 Deskset 注册——从不安装到 macOS 中。
  每次加载、刷新、安装和全部刷新时都会重新读取该文件夹（新增、替换和删除的字体都会被识别；缺失的文件夹 5 秒后会再次查找），
  已显示的皮肤会重新测量。此外，安装器还会把皮肤包放在其他位置的字体复制到 `@Resources\Fonts`（见
  [§11.2](#112-皮肤安装器)）。
- **原因：** macOS 按进程注册字体。
- **对皮肤的影响：** 添加到 `@Resources\Fonts` 的字体在“刷新皮肤”后生效。一个皮肤的字体可供 Deskset 中的所有其他皮肤使用
  （与 Windows 相同），但不提供给其他 Mac App。
- **状态：** 完全一致

#### AccurateText
- **Windows：** `AccurateText=0`（默认）按 GDI+ 的方式测量文字，带额外留白；1 使用更紧凑的度量。
- **Mac：** 0 在左右各加 1/6 em 的水平留白（通常引用的 GDI+ 数值）；1 使用 CoreText 的前进宽度。除非设置
  `TrailingSpaces=1`，末尾空白不计入宽度。尺寸向上取整到整像素。
- **原因：** GDI+ 的确切留白没有公开文档。
- **对皮肤的影响：** String meter 可能比 Windows 上宽或窄一两个像素。
- **状态：** 模拟实现

#### 空的 String meter
- **Windows：** 从 3.0 起，文字为空的 String meter 没有尺寸。
- **Mac：** 相同。例外：如果文字为空只是因为它的 measure *在 Mac 上* 没有数据（Windows 专属插件、未模拟的注册表值、
  没有 Mac 对应值的 SysInfo 类型），meter 会保留一行的高度。
- **原因：** 在 Windows 上这个值本来是有的；如果让这些行塌陷，下面的行就会叠在一起（在 FluentDash11 的 CPU / GPU 面板中
  观察到）。
- **对皮肤的影响：** 缺失数值下方的行保持原有间距；真正为空的文字与 Rainmeter 行为一致。
- **状态：** 完全一致（外加针对不可用数据的 Mac 专属规则）

#### 抗锯齿、Angle、裁剪与制表符
- **Windows：** `AntiAlias=1` 平滑文字；`Angle` 旋转文字而不改变尺寸和位置；ClipString 1 / 2。
- **Mac：** `AntiAlias=0` 会按选项要求绘制带锯齿的文字。取舍判断：Angle 围绕 StringAlign 锚点旋转，正弧度为顺时针，
  SolidColor 背景不旋转；ClipString=1 只有在同时设置 W 和 H 时才换行；ClipString=2 还会在最后一行可见文字上加 “…”；
  单个过长的单词直接裁剪，不加 “…”；制表位为字号的 4 倍；末尾换行不会产生空行。
- **原因：** 手册对这些细节没有规定。
- **对皮肤的影响：** 没有设置 `AntiAlias=1` 的皮肤在 Mac 上看起来比用户预期的更生硬。
- **状态：** 模拟实现

#### 内联选项（`InlineSetting`、`InlinePattern`）
- **Windows：** 由 DirectWrite 绘制。
- **Mac：** 手册中的每种 InlineSetting 都用 CoreText 绘制。取舍判断：CharacterSpacing 在行首字符前的前导间距保留为缩进；
  同类设置重叠时后面的生效；“alternative gamma” 的 GradientColor 在线性光空间插值；每个匹配项有自己的渐变框；内联
  Shadow 被裁剪在 meter 范围内。
- **原因：** CoreText 与 DirectWrite 在排版和间距细节上不同。
- **对皮肤的影响：** 间距有细微差异；Typography 特性取决于 Mac 字体是否支持。
- **状态：** 模拟实现

### 6.3 皮肤文件、变量、公式与选项

#### 皮肤文件（`.ini` / `.inc`、`@Include`）
- **Windows：** 节名和键名不区分大小写，`;` 开头为注释行，值两侧的引号会被忽略，重复的节被忽略，`@Include` 相当于把
  文件粘贴进来，相对路径从皮肤文件夹算起。
- **Mac：** 相同。取舍判断：去掉包住整个值的一对相同引号（`"` 或 `'`）；同一文件同一节中重复的键以第一个为准；位于任何节
  之前的 `@Include` 会被忽略并给出警告；找不到的包含文件还会在包含它的文件旁边查找，并且不区分大小写；支持 `\` 路径；
  编码支持 UTF-8 / UTF-16 / UTF-32（可检测时带或不带 BOM），否则按 Windows-1252；缺少右方括号的 `[Name` 行也算节标题；
  包含限制为 30 层、500 个文件、每个文件 32 MB。`!WriteKeyValue` 会给首尾有空格的值加引号，把换行变成空格；并且按手册
  只写入 `#SKINSPATH#` 或 `#SETTINGSPATH#` 下的文件。
- **原因：** 手册没有描述这些边界情况；后备查找只在文件原本会缺失时才生效。
- **对皮肤的影响：** 对有效的皮肤没有影响。
- **状态：** 完全一致（外加宽松处理）

#### 未设置 DynamicVariables 的选项中的节变量
- **Windows：** “节变量总是动态的”；要*更新*它们需要 DynamicVariables=1。手册没有说明非动态选项如何处理 `[Name]`；正常
  运行的皮肤（HDD Usage Bars、Mini Weather、HMNmeter2）表明它会被解析一次，然后保持不变。
- **Mac：** 未设置 DynamicVariables 的节，如果选项中引用了 measure 或 meter，会在第一次更新轮到它时（其上方的 measure
  已更新、上方的 meter 已定位）再读取一次选项，并在对它执行 `!SetOption` 之后再读取一次。这也包括 `MeterStyle`
  （`MeterStyle=StyleButton[MeasureState]`）。不指向任何节的 `[Name]` 保持原样。依赖节变量的值（MeterStyle 名称、引用了
  meter 的 Calc `Formula` 或 `IfCondition`）要等节变量解析之后才检查，有错时才记录日志。
- **原因：** 上述证据；加载时还没有 measure 数值和 meter 位置（具体时机是取舍判断）。
- **对皮肤的影响：** 未设置 DynamicVariables 而使用 `[Meter:X]` / `[Meter:W]` 的布局与 Windows 上一样对齐；measure 值
  取它的第一个值（Simple Clean 的问候语会显示用户名），需要变化的值仍然需要 `DynamicVariables=1`，与 Rainmeter 相同。
- **状态：** 模拟实现

#### 变量（细节）
- **Windows：** `#Var#`、`[#Var]`、转义 `#*Var*#` / `[*Name*]`、x0–xFFFE 范围内的字符变量 `[\x263A]`、最多十位小数
  的 `[M:]`。
- **Mac：** 相同，另外：字符变量接受任意 Unicode 码位（包括 emoji）和大写 `X`；变量的值在使用处会再次扫描（因此
  `!SetVariable V "[MeasureCPU]"` 相当于文本替换）；`#Var#` 先于节变量解析；`[M:%]` 限制在 0–100；`[M:/N]` 接受任意
  非零除数；数字四舍五入时 0.5 远离零；`:EscapeRegExp` 和 `:EncodeURL` 严格使用手册规定的字符集。普通选项中的 Windows
  环境变量（`%APPDATA%`）**不会**展开（插件和 Lua 会映射常见的几个，见 [§9](#9-内置插件核心) 和 [§8](#8-lua-脚本)）。
- **原因：** 手册未作规定时的取舍判断；macOS 能绘制所有 Unicode 平面。
- **对皮肤的影响：** 对有效的皮肤没有影响。
- **状态：** 完全一致（外加宽松处理）

#### 公式
- **Windows：** 使用“公式”页列出的运算符和函数；优先级未写明；`.5` 必须写成 `0.5`；`&&` / `||` 两侧“必须”加括号；`?:`
  最多嵌套 30 层。
- **Mac：** 采用类似 C 的优先级（从低到高：`?:`、`||`、`&&`、`= <>`、`< > <= >=`、`|`、`^`、`&`、`+ -`、`* / %`、一元
  `- + ~`、`**`）。除以零或对零取模以及非有限结果都得 0；`%` 是 C 的 `fmod`；`Round(x)` 0.5 远离零；`Min` / `Max` 可接受
  两个以上参数。宽松处理：`.5`、`5.`、`1e3`、所有公式中的小写 `0b` / `0o` / `0x` 前缀、不加括号的 `&&` / `||`、`==`、
  没有嵌套限制；普通数值选项取开头的数字（`12px` → 12）。
- **原因：** 公式绝不能导致崩溃或返回 NaN；手册未作规定时的取舍判断。
- **对皮肤的影响：** 对有效的公式没有影响；一些 Rainmeter 会拒绝的公式在 Mac 上可以运行。
- **状态：** 完全一致（外加宽松处理）

#### 带 `0x` 前缀的十六进制颜色
- **Windows：** 手册只写了 `RRGGBB[AA]` 和 `R,G,B[,A]`。
- **Mac：** 也接受 `0xRRGGBB` / `0xRRGGBBAA`（`0x` 或 `0X`）。
- **原因：** 取舍判断——实际皮肤中有人把所有颜色都写成这种形式（EasyInfo），说明作者在 Windows 上看到的颜色是正常的。
- **对皮肤的影响：** 这类皮肤显示为作者预期的颜色。
- **状态：** 模拟实现

#### 拼错的和旧式的选项名
- **Windows：** 手册没有写，但正常运行的皮肤在 Roundline / Rotator 上用 `ValueReminder` 代替 `ValueRemainder`（Enigma
  的时钟、Elegant Watch），指针照样转动。
- **Mac：** 凡是读取 `ValueRemainder` 的地方也接受 `ValueReminder`（两者都设置时以正确拼写为准）；Image meter 已弃用的
  `Path` 可用。其他拼写错误（`GrayScale`、`Substitue`）不做兼容，因为没有证据表明 Rainmeter 接受它们。
- **原因：** 正常运行的皮肤中观察到的行为。
- **对皮肤的影响：** 使用了错误拼写的模拟时钟指针也能转动。
- **状态：** 完全一致（依据观察）

#### 数字格式（NumOfDecimals、AutoScale、Scale、Percentual）
- **Windows：** AutoScale 取 `0`、`1`、`1k`、`2`、`2k`，单位为 k、M、G；单位前有统一的空格。
- **Mac：** 单位为 k、M、G、T；作为扩展接受 `1m` / `1g` / `1t` / `2m` / `2g` / `2t`；总是加空格，即使没有单位（带
  AutoScale 的 `Text="%1 %"` 显示 “96.2  %”）；单位根据取整前的值选择；带小数点的 Scale 在未设置 NumOfDecimals 时显示
  1 位小数；Percentual 限制在 0–100；按 printf 规则取整（2.5 → “2”）；NumOfDecimals 限制在 0–30。
- **原因：** 手册未作规定时的取舍判断（未与 Windows 对照验证）。
- **对皮肤的影响：** AutoScale 的结果可能多一个空格或末位取整不同。
- **状态：** 模拟实现

#### 时间与开机时长格式
- **Windows：** 带 `#` 标志的 strftime 格式码；数值 = 自 1601 年起的秒数；Uptime 用 `%1`…`%4` 加 printf 格式；
  FormatLocale 使用 Windows 的区域数据。
- **Mac：** 格式码相同。取舍判断：`%r` 为大写的 “10:55:03 PM”；`%Z` 为英文时区名；未知格式码原样输出；Format 为空时
  等同 `%H:%M:%S`；设置了 Format 时，数值取文字开头的数字；TimeZone 接受小数小时，且不作用于 TimeStamp 的值（数字形式的
  也不作用）；TimeStamp 解析较宽松；AddDaysToHours 默认为 1。区域格式（`%c`、`%x`）来自 macOS（ICU）数据。
  FormatLocale / TimeStampLocale 通过内置的常用区域表识别 Windows 的三字母语言代码（`DEU`、`CHS`……）和 `Language_Country`
  名称。
- **原因：** macOS 的区域数据；手册没有规定细节。
- **对皮肤的影响：** 本地化日期的写法可能略有不同（例如德语 `%c` 中的两位数年份）；表中没有的少见 Windows 区域名称使用默认
  区域。
- **状态：** 模拟实现

#### 动作、bang、Substitute 与正则表达式
- **Windows：** `[!Bang arg "arg"]`、魔术引号 `"""…"""`、旧式 `!Rainmeter…` 名称；Substitute 和 RegExpSubstitute 使用
  PCRE。
- **Mac：** 语法相同；bang 名称不区分大小写；引号内的方括号不会结束 bang；方括号 bang 之间的文字被忽略；`!Execute` 嵌套
  最多 8 层。普通替换区分大小写；接受 `'a':'b'`（手册说这种写法会失败）。正则表达式是转换为 ICU 的 PCRE：`(?U)`、环视
  和命名分组可用；`(?|…)` 会重新编号分组，`\K` 被去掉，条件分支变为普通的多选分支，不支持递归；`\w`、`\d` 和 `(?i)`
  支持 Unicode；`.` 和 `$` 也把 `\r` 当作行尾；每次正则操作最多占用 1 秒 CPU 时间（系统繁忙时最多 10 秒）。
- **原因：** macOS 自带的是 ICU，而不是 PCRE。
- **对皮肤的影响：** 常见写法如 `(?siU)<tag>(.*)</tag>` 行为相同；冷门的 PCRE 特性可能无法匹配。
- **状态：** 完全一致（常见写法）/ 部分支持（冷门 PCRE 特性）

#### 更新间隔与 Counter
- **Windows：** `Update` 最小 16 ms，-1 表示只更新一次；Calc 的 `Counter` 只有在皮肤卸载后才重置。
- **Mac：** 相同。
- **原因：** 按手册。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 向用户显示的兼容性提示
- **Windows：** 错误和警告写入日志。
- **Mac：** *兼容性提示*（菜单和管理窗口中）只列出在 Mac 上表现不同的内容：Windows 专属的 measure 和插件、不支持的 bang、
  没有 Mac 对应值的注册表值和 SysInfo 类型、不支持的 Histogram 图像选项、WebParser 的证书相关选项，以及在 App 中被拒绝的
  权限、没有 Mac 版本的播放器和 WebNowPlaying 浏览器扩展（见 [§4](#4-macos-权限)）。权限相关的提示在授予权限后会自动消失。
  皮肤自身的错误（缺失的 MeterStyle、无效的 Container、拼错的 bang 或 measure 类型）只记录日志。
- **原因：** 皮肤自身的错误在 Rainmeter 中表现相同，不属于 Mac 差异。
- **对皮肤的影响：** 提示更少、更有针对性；编写皮肤时的警告仍在日志中。
- **状态：** 仅 Mac

### 6.4 Measure

#### “以前是插件”的 measure
- **Windows：** SysInfo、Process、WebParser、RecycleManager、MediaKey、NowPlaying 和 WiFiStatus 仍可写成
  `Measure=Plugin` + `Plugin=Name`（`Name.dll`、`Plugins\Name.dll`）。
- **Mac：** 两种写法都可以；Deskset 实现的插件用哪种写法都能找到。
- **原因：** 按手册。
- **对皮肤的影响：** 使用插件语法的老皮肤可以正常运行，不会出现提示。
- **状态：** 完全一致

#### CPU
- **Windows：** 0–100；`Processor=0` 为所有核心，N 为第 N 个核心。
- **Mac：** 使用 Mach 主机统计（user + system + nice）。核心数是 Mac 的逻辑核心数（Apple 芯片上为性能核和能效核，没有
  超线程）。第一次读数是开机以来的平均值，之后是每个更新间隔内的使用率。
- **原因：** macOS 的 CPU 负载来源；第一次读数为 0 会让固定尺寸的皮肤过窄。
- **对皮肤的影响：** 各核心图表显示 Mac 的核心数。
- **状态：** 模拟实现

#### Memory、PhysicalMemory、SwapMemory
- **Windows：** PhysicalMemory = 物理内存，SwapMemory = 页面文件，Memory = 物理内存 + 页面文件（“提交大小”）。
- **Mac：** 用 macOS 的交换空间代替页面文件：PhysicalMemory = 物理内存（已用 = App 内存 + 联动内存 + 压缩内存，即“活动
  监视器”中的“已使用内存”）；SwapMemory = 物理内存 + 交换空间；Memory = 两者相加（总量 = 2 × 物理内存 + 交换空间）。
  `Free=1` 给出总量 − 已用。MaxValue 自动设定。
- **原因：** macOS 没有固定大小的页面文件；严格遵循手册的定义。
- **对皮肤的影响：** Mac 用户可能以为 SwapMemory 只是交换空间；Memory / SwapMemory 的百分比在“活动监视器”中没有对应项。
- **状态：** 模拟实现

#### NetIn / NetOut / NetTotal
- **Windows：** 字节 / 秒；`Interface` = Best（默认）、0 = 全部、N 或网卡名称。
- **Mac：** Best = 当前活动接口（有线优先于 Wi-Fi）；0 = 除 VPN 隧道、AWDL、网桥等虚拟接口以外的所有活动接口（避免重复
  计数）；不存在的 Windows 网卡名（`Wi-Fi`、`Realtek PCIe GBE…`）或序号会回退到 Best（记录一次日志）。`Cumulative=1`
  从开机起计数；重启后不保留统计，不支持 `!ResetStats`。
- **原因：** macOS 的接口名（`en0`）与 Windows 网卡名不同。
- **对皮肤的影响：** 指定了 Windows 网卡名的皮肤测量的是 Mac 当前的活动接口。
- **状态：** 模拟实现

#### FreeDiskSpace
- **Windows：** `Drive=C:`；Total、Label、Type、IgnoreRemovable。
- **Mac：** 所有盘符（`C:`、`D:`、`C:\`）都表示启动卷 `/`；单独的名称（`Data`）表示 `/Volumes/Data`；也可以写绝对路径。
  在 APFS 上数值取整个容器的（与访达显示一致）。Type 根据卷属性判断（USB 硬盘算作 Fixed）。
- **原因：** macOS 没有盘符。
- **对皮肤的影响：** D:、E:、F: 都重复显示启动磁盘；其他卷请写 `Drive=/Volumes/Backup`。
- **状态：** 模拟实现

#### SysInfo
- **Windows：** 系统、用户、网卡、显示器和时区等信息。
- **Mac：** 显示器数值以点为单位（显示器 1 = 主屏幕），`SCREEN_SIZE` 形如 “1920 x 1080”，时区数值采用 Windows 的符号约定，
  系统相关数值给出 macOS 的名称，`DOMAIN_WORKGROUP` 是 SMB 工作组，`INTERNET_CONNECTIVITY` 检查默认路由（而不是
  SysInfoData 指定的网卡）。没有 Mac 对应值的类型（`USER_SID`、`ADAPTER_GUID`）为 0 / 空，并显示兼容性提示。
- **原因：** 有些类型是 Windows 独有的概念。
- **对皮肤的影响：** 网卡相关类型需要 Mac 的接口；显示器尺寸以点为单位。
- **状态：** 模拟实现 / 部分支持

#### Registry（注册表）
- **Windows：** 读取任意注册表值。
- **Mac：** 没有注册表。皮肤常用来读取机器信息的值会用 macOS 的对应数据回答（键不区分大小写，接受 `WOW6432Node` 和
  `ControlSet00N`）：`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` 下的 Windows 版本键（ProductName 为
  “macOS Tahoe”、CurrentVersion、各种版本号、RegisteredOwner……）、WinSat 的 `PrimaryAdapterString`（Apple 芯片上是芯片名称，Intel Mac 上是显卡名称）、
  `CentralProcessor\N`（ProcessorNameString，Apple 芯片上 `~MHz` = 0）、`NUMBER_OF_PROCESSORS`、
  `PROCESSOR_ARCHITECTURE`、`PROCESSOR_IDENTIFIER`、计算机名、`USERNAME`、`USERPROFILE` 以及用户 Shell 文件夹（桌面、
  文稿、音乐、图片、影片、下载）。`HKCU\Control Panel\Desktop` 的 `Wallpaper` 是主显示器当前桌面图片的路径（没有图片文件时
  为空），每次更新时重新读取。桌面图片是一个轮换图片的文件夹时，macOS 不会告诉我们正在显示哪一张，因此取该文件夹中按名称排序的
  第一张图片（也是 Chameleon 取色所用的那一张）；文件夹在后台读取，所以在读取完成后该 measure 的第一次更新之前，该值为空
  （皮肤加载后片刻；对于很少更新的 measure 会更晚，例如 Enigma 的 `UpdateDivider=30`）。其他值为 0 / 空，并作为兼容性提示
  列出一次。显存有意不做模拟：Apple 芯片的 GPU 使用统一内存，任何数字都不具有相同的含义。
- **原因：** 给出 Mac 上的答案比显示空行更有用。
- **对皮肤的影响：** 针对 Windows 版本号的判断（`CurrentBuild >= 22000`）看到的是 “25F71” 这样的 macOS 构建号，其数值为 0。
  显示显存的皮肤显示 0。壁纸缩略图（Enigma 的布局选项）显示桌面图片；使用轮换图片时，显示的可能是文件夹中的另一张图片，而不是
  屏幕上正在显示的那一张。
- **状态：** 模拟实现（固定的一组值）

#### Windows 专属的 measure 和插件
- **Windows：** Windows 内置 measure 和第三方插件 DLL。
- **Mac：** 大部分已重新实现（见[插件矩阵](#5-插件支持矩阵)）。未提供的部分——其他任何 Windows DLL——数值为 0 / 空，
  `!CommandMeasure` 不起作用，并显示兼容性提示。只显示这种数值的 String meter 保留一行高度。
- **原因：** Windows DLL 无法在 macOS 上运行。
- **对皮肤的影响：** 皮肤中相应的部分保持空白；皮肤绝不会崩溃。
- **状态：** 不支持（后备处理）

#### 其他 measure 细节（取舍判断）
- **Windows：** 手册没有规定这些细节。
- **Mac：**
  - 没有 MinValue / MaxValue 的 Calc、Net、WebParser、Script 以及数值会变化的核心插件 measure 从 0…1 开始，根据出现过的数值
    扩大范围（“Measures → Percentage”）；只写 `MaxValue=100` 时范围为 0…100。
  - 单次更新内的顺序：取值 → 范围 → 平均 → 反转 → IfCondition → IfAbove / IfBelow / IfEqual → IfMatch →
    OnChangeAction → OnUpdateAction。数值离开区间后 IfAbove / IfBelow 重新待命；IfEqual 比较取整后的值；缺少
    `IfAboveValue` 的 `IfAboveAction` 永远不会触发。
  - Loop 总是按 |Increment| 从 StartValue 走向 EndValue。
  - Time 的数值是当地时间自 1601 年起的秒数，取整秒。
  - PowerPlugin：没有电池的 Mac 上 `Percent` 为 100、`ACLine` 为 1；未知时 `Lifetime` 为 -1 / “Unknown”；Apple 芯片上
    `Hz` / `MHz` 为 0（没有公开的 CPU 频率）。
  - Process：ProcessName 中的 `.exe` 会被去掉；Mac 的进程名往往与 Windows 的可执行文件名不同。
- **原因：** 手册未作规定时的取舍判断。
- **对皮肤的影响：** 只涉及边界情况（绑定到 Bar 的常量 Calc 需要 MaxValue，与 Rainmeter 相同）。
- **状态：** 模拟实现

### 6.5 Meter 与绘制

#### 绑定的 measure（`MeasureName`、`MeasureName2`……）
- **Windows：** `%1`、`%2`…… 是 MeasureName、MeasureName2…… 的值。
- **Mac：** 相同；如果 `MeasureName` 指向不存在的 measure，第 1 个位置保持为空（不会把 MeasureName2 挪上来）；`%N`
  只替换一遍。
- **原因：** 按手册。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 图片文件
- **Windows：** 没有扩展名时“假定为 .png”；支持 png、jpg、bmp、gif、tif、webp、ico。
- **Mac：** 相同，另外支持 jpeg、jpe、dib、tiff 和 heic；如果扩展名不是图片类型（例如 measure 值 “12.5”），同样会补上
  `.png`，除非恰好存在这个文件；每次使用都会重新检查文件，因此修改过的图片无需 DynamicVariables 就会显示；每边超过
  8192 像素的图片会被缩小。
- **原因：** 不会破坏有效皮肤的宽松处理；尺寸上限用于控制内存。
- **对皮肤的影响：** 对普通图片没有影响。
- **状态：** 完全一致（外加宽松处理）

#### 图像选项
- **Windows：** “通用图像选项”；处理顺序和颜色计算没有写明。
- **Mac：** 先 ImageFlip 后 ImageRotate（顺时针）；裁剪和旋转在 EXIF 方向之后；裁剪超出图片的部分为透明；ImageTint 按相乘
  计算；Greyscale 使用 Rec. 601 权重；ColorMatrix 取代 ImageTint / ImageAlpha（Greyscale 仍先执行）；只设置 W / H 之一时，
  除非写明 `PreserveAspectRatio=0`，另一边按比例；遮罩取两者中更透明的 alpha；支持 `UseExifOrientation=1`（默认 0 = 按
  存储的像素）。不支持 Histogram 的 `PrimaryImageRotate` 和 ColorMatrix 选项（显示兼容性提示）。
- **原因：** 手册未作规定时的取舍判断；CoreGraphics 的缩放方式。
- **对皮肤的影响：** 着色或灰度处理后的图片色调可能略有差别。
- **状态：** 模拟实现 / 部分支持

#### Bar、Bitmap、Button
- **Windows：** 见 Bar、Bitmap 和 Button 页面。
- **Mac：** Bar 的填充长度为整像素；BarImage 按其原尺寸绘制，BarBorder 两端始终绘制。Bitmap / Button 的图片条在宽大于高
  时为横向；BitmapZeroFrame 和过渡效果按手册；BitmapAlign 与 StringAlign 相同。Button 的点击检测忽略透明像素；Button
  自身的鼠标动作仍会执行。
- **原因：** 手册未作规定时的取舍判断。
- **对皮肤的影响：** 预计无。
- **状态：** 模拟实现

#### Roundline 与 Rotator
- **Windows：** 一些默认值和取模细节没有写明。
- **Mac：** 默认 StartAngle 0、RotationAngle 2π、LineStart 0、LineLength 0；ValueRemainder 使用浮点取模（指针平滑转动），
  负值会回绕，此模式下忽略 MinValue / MaxValue；没有绑定 measure 时视为 100 %；带 ControlStart / ControlLength 的 Solid
  绘制扇形；Rotator 的图片按其像素尺寸绘制（不裁剪到 W×H），并始终平滑处理。
- **原因：** 手册中的时钟示例只有这样才能工作；其余为取舍判断。
- **对皮肤的影响：** 数值带小数时，时钟指针会平滑转动。
- **状态：** 模拟实现

#### Line 与 Histogram
- **Windows：** 见 Line 和 Histogram 页面。
- **Mac：** GraphOrientation=Horizontal 相当于把竖向图表顺时针旋转 90°；尚未填满的历史记录按 0 处理（新图表一开始是一条
  平线）；没有 AutoScale 时，范围从最小的 MinValue 到最大的 MaxValue（Line），或各 measure 自己的范围（Histogram）；
  HorizontalLines 在四等分处画 3 条线；LineColor 默认为白色；隐藏的 meter 仍会采样，`!UpdateMeter` 也会添加一个采样。
- **原因：** 手册未作规定时的取舍判断。
- **对皮肤的影响：** 新图表从一条平线开始，而不是从一侧逐渐长出来。
- **状态：** 模拟实现

#### Shape
- **Windows：** Direct2D 几何图形。
- **Mac：** 使用 CoreGraphics。W / H 取描边后的外框并取整到整像素（与手册截图一致）；超过斜接限制的斜接转角改为斜切；
  虚线在每个图形中重新开始；形状始终抗锯齿；缺失的必需参数按 0 处理（FluentDash11 写的是 `Rectangle ,,100,50,8`）；
  `StrokeType` 和 Combine 的 `Consume` 标志作为扩展被接受；组合形状的外框取上界。渐变几何、Arc 的扫掠方向和变换锚点
  遵循手册默认值，手册未作规定时采用类似 CSS / SVG 的选择。
- **原因：** 用 CoreGraphics 代替 Direct2D。
- **对皮肤的影响：** 非常尖锐的斜接转角和组合形状可能相差一个像素。
- **状态：** 模拟实现

#### 鼠标点击区域
- **Windows：** 皮肤中完全透明的像素不响应点击。
- **Mac：** meter 的矩形区域接收鼠标（Shape：其实心部分；Button：其不透明像素）；点击完全透明的像素会传给后面的窗口。
- **原因：** AppKit 对无边框透明窗口按像素 alpha 做点击检测。
- **对皮肤的影响：** 带有不可见 `SolidColor=0,0,0,1` 的 meter 可以接收点击，与 Windows 相同。
- **状态：** 完全一致

### 6.6 动作与鼠标

#### `!Delay`
- **Windows：** 延迟期间“皮肤将没有响应”。
- **Mac：** 动作的剩余部分稍后执行；皮肤继续更新；刷新或卸载会取消尚未执行的部分。
- **原因：** 阻塞会冻结所有皮肤和整个 App。
- **对皮肤的影响：** 更新可能在被延迟的动作中间执行。
- **状态：** 模拟实现

#### OnFocusAction、OnUnfocusAction、OnWakeAction
- **Windows：** 在“更新周期的最后”执行。
- **Mac：** 焦点动作在焦点变化时执行（`Update=-1` 的皮肤永远不会再有下一次更新）；OnWakeAction 在 Mac 唤醒后第一次更新
  结束时执行（`Update=-1` 时立即执行）。
- **原因：** 见上。
- **对皮肤的影响：** 预计无。
- **状态：** 模拟实现

#### bang 中的公式
- **Windows：** bang 中（公式）里使用的 measure 不需要 DynamicVariables。
- **Mac：** 如果 `!SetOption` 的值是一个引用了 measure 的带括号公式，会在 bang 执行时求值；通过 `!SetOption` 设置的 Calc
  `Formula` / `IfCondition` 按原文保存；`!SetVariable` / `!WriteKeyValue` 的结果最多保留 10 位小数。
- **原因：** 细节上的取舍判断。
- **对皮肤的影响：** 预计无。
- **状态：** 完全一致

#### 动作选项中的变量（`#Var#`）
- **Windows：** “选项类型”页说在动作选项中使用 `#VarName#` 时会用变量的“当前值”；“变量”页则说 bang 中的节变量自动是动态的，
  但没有对 `#Var#` 作同样的说明。
- **Mac：** 动作选项（鼠标动作、IfTrueAction、OnUpdateAction、FinishAction……）中的 `#Var#` 在读取该节选项时替换——加载时、
  对该节执行 `!SetOption` 之后，以及设置了 `DynamicVariables=1` 时的每次更新。节变量（`[Measure]`）、嵌套写法 `[#Var]` 和
  转义在动作执行时才解析。
- **原因：** 手册各页说法不一致时的取舍判断。
- **对皮肤的影响：** 执行 `!SetVariable` 之后，没有 DynamicVariables 的节中的动作仍使用 `#Var#` 的旧值。请给该节加上
  `DynamicVariables=1`，或者改写为 `[#Var]`，它总是给出当前值。
- **状态：** 模拟实现（取舍判断）

#### 键盘修饰键与滚动
- **Windows：** 拖动时按住 Ctrl 可临时覆盖 Draggable / SnapEdges；鼠标滚轮动作。
- **Mac：** 用 ⌘ 代替 Ctrl（在 Mac 上 Control-点按会打开上下文菜单）；滚动动作按物理方向执行（抵消“自然滚动”）；触控板每
  移动 24 个点触发一次滚动动作，惯性滚动期间不触发。详见 [§7.2](#72-鼠标)。
- **原因：** macOS 的惯例。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 失控的动作
- **Windows：** 没有写明限制。
- **Mac：** 互相触发的动作在每次更新 20 000 步或嵌套 16 层后停止（记录日志）；更新过程中的 `!Update` 会被忽略。
- **原因：** 皮肤绝不能让 App 卡死。
- **对皮肤的影响：** 只影响本来会卡死的皮肤。
- **状态：** 仅 Mac

### 6.7 安全限制

- **Windows：** 手册没有给出限制。
- **Mac：** X、Y、W、H 在 ±1 000 000 点以内；皮肤窗口每边最多 8192 点（`--render` 中为 16 384）；String meter 的文字最多
  32 768 个 UTF-16 单元（4 096 个内联范围、5 000 行）；FontSize 为 0…1000；图片每边最多按 8192 像素解码，ImageCrop 的尺寸
  最多 32 768 像素，处理后的副本会超过 1670 万像素的图片不做颜色处理（着色、Greyscale、ColorMatrix）直接绘制；每个皮肤最多
  500 条不同的“只记录一次”消息和提示，最多 256 个待执行的 `!Delay`。
- **原因：** 恶意或错误的公式不能耗尽内存或让 App 崩溃。
- **对皮肤的影响：** 对真实的皮肤没有影响。
- **状态：** 仅 Mac

---

## 7. App、窗口与 bang

菜单栏 App 围绕引擎所做的一切：每个皮肤一个无边框窗口、窗口设置（Rainmeter 保存在 Rainmeter.ini 中，Deskset 保存在
`~/Library/Application Support/Deskset/state.json` 中）、鼠标处理、菜单，以及窗口、配置和应用程序类 bang。详细说明：
[`compat/app.md`](compat/app.md)。

### 7.1 皮肤窗口

#### 窗口层级（`AlwaysOnTop`、`!ZPos`）
- **Windows：** 2 Stay Topmost、1 Topmost、0 Normal（默认）、-1 Bottom、-2 On Desktop；除 Bottom 以外的皮肤在显示桌面时
  保持可见。
- **Mac：** 使用 macOS 的窗口层级。On Desktop = 紧贴在访达桌面图标之上（仍可点按和拖动）；Bottom = 在普通窗口之下；Normal =
  普通层级；Topmost = 浮动层级；Stay Topmost = 紧贴在菜单栏之下（会盖住程序坞）。每个皮肤都出现在所有“空间”中。除 Bottom
  以外的所有层级在“显示桌面”、“调度中心”和“台前调度”期间保持不动；Bottom 会被它们隐藏。Topmost 和 Stay Topmost 也显示在
  全屏 App 之上。处于同一层级的皮肤按 Load Order、再按名称叠放。
- **原因：** macOS 使用窗口层级，而不是 Windows 的 Z 顺序分段。
- **对皮肤的影响：** 预计无；Stay Topmost 的皮肤会盖住程序坞。
- **状态：** 模拟实现

#### 新皮肤默认位于桌面层
- **Windows：** 第一次加载的配置从 AlwaysOnTop=0（Normal）开始。
- **Mac：** 除非皮肤设置了 `DefaultAlwaysOnTop`，否则从 On Desktop（-2）开始。
- **原因：** 产品决定——Mac 用户希望小组件待在桌面上，而不是盖在文稿上面。
- **对皮肤的影响：** 新加载的皮肤位于所有窗口之后；可以在皮肤菜单 → 位置中修改。
- **状态：** 模拟实现（取舍判断）

#### `[Rainmeter]` 中的 `Default…` 选项
- **Windows：** `DefaultWindowX/Y`、`DefaultAnchorX/Y`、`DefaultSavePosition`、`DefaultAlwaysOnTop`、`DefaultDraggable`、
  `DefaultSnapEdges`、`DefaultStartHidden`、`DefaultAlphaValue`、`DefaultOnHover`、`DefaultFadeDuration`、
  `DefaultClickThrough`、`DefaultKeepOnScreen`、`DefaultAutoSelectScreen` 在第一次加载时为配置提供初始设置。
- **Mac：** 相同，只是用 state.json 代替 Rainmeter.ini；位置接受 WindowX / WindowY 的各种写法（`%`、`R` / `B`、公式、
  `@N`）。锚点只在摆放皮肤时应用一次（见下面的“位置”）。
- **原因：** —
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 拖动、`DragMargins` 与 Ctrl 覆盖
- **Windows：** Draggable（默认 1）；设置了 LeftMouseDownAction 就不能拖动；DragMargins 限制可以开始拖动的区域；按住 Ctrl
  可以覆盖鼠标动作和 Draggable。
- **Mac：** 规则相同；移动 3 个点后开始拖动。覆盖键是 **⌘（Command）**：按住 ⌘ 拖动可以移动任何皮肤，且不执行点按动作；拖动时
  按 ⌘ 会反转 SnapEdges。拖动结束时保存位置。
- **原因：** 在 Mac 上 Control-点按是辅助（右键）点按。
- **对皮肤的影响：** 说明文件中写的“按住 CTRL”在 Mac 上指 ⌘。
- **状态：** 模拟实现

#### `DragGroup`（一起移动多个皮肤）
- **Windows：** 同一 DragGroup 的皮肤可以一起选中并拖动。
- **Mac：** 不支持；每个皮肤单独移动。
- **原因：** 尚未实现。
- **对皮肤的影响：** 分组的皮肤需要逐个移动。
- **状态：** 不支持

#### SnapEdges 与 KeepOnScreen
- **Windows：** 皮肤会吸附到屏幕边缘和其他皮肤；KeepOnScreen 让皮肤保持在屏幕范围内。
- **Mac：** 距离屏幕边缘（整个屏幕以及菜单栏下方 / 程序坞旁边的区域）或附近皮肤的边缘 10 个点以内时吸附。KeepOnScreen 让
  窗口保持在与它重叠最多的屏幕上、菜单栏之下（可以进入程序坞区域）；比屏幕还大的皮肤保持左上角可见。即使关闭
  KeepOnScreen，完全离开所有屏幕的皮肤（例如拔掉了显示器）也会被移回来。
- **原因：** 位于菜单栏下面或所有屏幕之外的窗口永远无法再够到。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### ClickThrough（点击穿透）
- **Windows：** 关闭鼠标检测，点击会穿透；“按住 CTRL 可暂时停用”。
- **Mac：** 窗口完全忽略鼠标（没有点按、悬停、工具提示和滚动）。**不能**用 Ctrl / ⌘ 临时覆盖，因为 macOS 不会向这样的窗口
  传递任何事件。请在菜单栏菜单中该皮肤的子菜单或管理窗口中关闭它。
- **原因：** macOS 的窗口模型。
- **对皮肤的影响：** 点击穿透的皮肤即使按住 ⌘ 也无法拖动。
- **状态：** 部分支持

#### AlphaValue、OnHover 与淡入淡出
- **Windows：** AlphaValue 为 0…255；菜单提供 0 %…90 % 的透明度；OnHover 0 无、1 隐藏、2 淡入、3 淡出；FadeDuration（默认
  250 ms）用于 OnHover 和 `!ShowFade` / `!HideFade` / `!ToggleFade`。
- **Mac：** 相同。取舍判断：OnHover=Hide 在皮肤于指针下隐藏期间还会让点击穿透（淡出则保留鼠标动作）；每 100 ms 轮询一次
  指针位置，因此点击穿透的皮肤也能用；皮肤加载时会淡入、卸载时会淡出（刷新时不会）；FadeDuration 限制在 0…10 000 ms。
- **原因：** 手册对“隐藏”和“淡出”的描述相同；输错的数值不能让皮肤卡住。
- **对皮肤的影响：** 预计无。
- **状态：** 模拟实现

#### StartHidden
- **Windows：** 皮肤启动时隐藏；`!Show` 显示它。
- **Mac：** 相同（也可来自 `DefaultStartHidden`）；隐藏的皮肤继续更新并执行其动作。
- **原因：** —
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 位置（`WindowX` / `WindowY`、SavePosition、`!Move`、`!SetWindowPosition`、AutoSelectScreen）
- **Windows：** 虚拟桌面上的像素位置；SavePosition 保存拖动结果；`!SetWindowPosition` 接受 `%`、`R` / `B`、`@N` 和锚点；
  皮肤的锚点（`AnchorX` / `AnchorY`、`!SetAnchor`）与位置一起保存。
- **Mac：** 以点为单位，原点在主显示器（带菜单栏的那个）的左上角，y 向下增大——约定相同，只是单位为点。`!Move` 的数值限制
  在 ±1 000 000 以内。关闭 SavePosition 时，位置只在本次运行期间有效。没有保存位置也没有默认位置的新皮肤从可见区域的左上角
  开始层叠摆放。AutoSelectScreen 决定不带 `@N` 的显示器变量描述哪块显示器。锚点（`DefaultAnchorX` / `DefaultAnchorY`、
  `!SetWindowPosition` 的锚点参数）只在摆放皮肤时应用一次；保存的位置始终是窗口的左上角，不支持 `!SetAnchor`。
- **原因：** macOS 以点为单位（Retina）；尚未实现保存的锚点。
- **对皮肤的影响：** 按特定 Windows 分辨率摆放的皮肤在 Retina Mac 上会落在别处；KeepOnScreen 会让它们保持可见。锚定在右侧或
  底部的皮肤改变尺寸时（DynamicWindowSize）会向右、向下扩展，而不是围绕锚点变化。
- **状态：** 模拟实现 / 部分支持（保存的锚点）

#### 显示器变化
- **Windows：** 除 KeepOnScreen 和显示器变量外没有描述。
- **Mac：** 连接、断开或重新排列显示器时，有保存位置的皮肤会按保存的位置重新放置（显示器回来时皮肤也会回到它上面），并保持在
  屏幕内。皮肤不会被刷新；设置了 DynamicVariables=1 的节中显示器变量会随之变化。
- **原因：** 取舍判断；刷新所有皮肤会重置它们的状态。
- **对皮肤的影响：** 没有 DynamicVariables、根据 `#SCREENAREAWIDTH#` 计算布局的皮肤，在刷新之前保持原来的布局。
- **状态：** 模拟实现

#### 睡眠、显示器睡眠、其他用户会话
- **Windows：** OnWakeAction 在“Windows 从睡眠或休眠状态恢复时”执行。
- **Mac：** Mac 睡眠、显示器睡眠或切换到其他用户的会话期间，皮肤计时器停止，音频采集也停止（不显示录音指示点）。恢复后立即
  更新一次；真正的睡眠之后，OnWakeAction 在这次更新结束时执行。用 `!Hide` 隐藏的皮肤继续更新，并保留其音频采集。
- **原因：** 节能；macOS 把显示器睡眠和会话切换与系统睡眠分开报告。
- **对皮肤的影响：** 基于时间的 measure 在暂停后会向前跳。
- **状态：** 模拟实现

#### 焦点（`OnFocusAction` / `OnUnfocusAction`）
- **Windows：** 点按皮肤时皮肤“获得焦点”，点按其他地方时“失去焦点”。
- **Mac：** 皮肤窗口从不激活 Deskset（最前面的 App 保持在最前面）。只有设置了 OnFocusAction 或 OnUnfocusAction 的皮肤窗口
  才会获取键盘焦点；macOS 一报告变化就执行这些动作（时机见 [§6.6](#66-动作与鼠标)）。在获得焦点的皮肤中打字会被静默吞掉。
- **原因：** Mac 小组件使用的是非激活面板。
- **对皮肤的影响：** 预计无。
- **状态：** 模拟实现

#### Blur 和 BlurRegion（`[Rainmeter]`）以及模糊类 bang
- **Windows：** “设为 1 以启用 Aero 模糊”；`!ShowBlur`、`!AddBlur`…… 可以修改它。
- **Mac：** 不支持（FrostedGlass 插件是支持的，见 [§10.7](#107-窗口桌面与颜色插件第三方)）；这些 bang 会添加兼容性提示。
- **原因：** 尚未实现。
- **对皮肤的影响：** 皮肤没有模糊背景。
- **状态：** 不支持

### 7.2 鼠标

#### 右键与皮肤菜单
- **Windows：** 右键打开皮肤菜单，除非设置了 RightMouse…Action；Ctrl+右键总是打开它。
- **Mac：** 规则相同；Control-点按（Mac 的辅助点按）和 ⌘+右键总是打开皮肤菜单。
- **原因：** Mac 的惯例。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 中键、X1 和 X2 键
- **Windows：** Middle / X1 / X2 鼠标动作。
- **Mac：** 鼠标按键 3、4、5 执行这些动作。触控板没有这些按键。
- **原因：** —
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 滚动动作
- **Windows：** MouseScrollUp/Down/Left/RightAction 每个滚轮刻度执行一次。
- **Mac：** 滚轮刻度一一对应。触控板每滑动 24 个点执行一次动作（每个事件最多 10 次），惯性滚动期间不执行。方向按物理方向——
  手指向上就是“向上”，与“自然滚动”设置无关。
- **原因：** Windows 皮肤期望离散的刻度；否则“自然滚动”会让所有皮肤方向颠倒。
- **对皮肤的影响：** 靠滚动操作的皮肤（音量、列表）手感与 Windows 相同。
- **状态：** 模拟实现

#### 按住按键时的悬停
- **Windows：** 没有描述。
- **Mac：** 按住鼠标按键期间不更新 MouseOver / MouseLeave；松开时再报告。
- **原因：** 引擎把悬停更新视为一次按压的结束。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 光标（`MouseActionCursor`、`MouseActionCursorName`）
- **Windows：** 在有鼠标动作的 meter 上显示手形；MouseActionCursorName 接受 Windows 光标名称或 `@Resources\Cursors` 中的
  `.cur` / `.ani` 文件。
- **Mac：** HAND、TEXT、CROSS、NO、SIZE_WE 和 SIZE_NS 映射为 macOS 光标；其他名称（HELP、BUSY、WAIT、PEN、SIZE_ALL、对角线
  调整、UPARROW）和自定义 `.cur` / `.ani` 文件显示箭头。Button meter 显示手形；只有 MouseOverAction / MouseLeaveAction
  这类鼠标动作的 meter 不显示手形（取舍判断）。
- **原因：** macOS 没有这些光标的公开对应物；`.cur` / `.ani` 是 Windows 格式。
- **对皮肤的影响：** 有些皮肤在 Windows 上显示自定义光标的地方显示箭头。
- **状态：** 部分支持

#### 工具提示
- **Windows：** ToolTipText / ToolTipTitle、ToolTipIcon、ToolTipType（气泡）、ToolTipWidth；`[Rainmeter]` 中的
  ToolTipHidden。
- **Mac：** 标准的 macOS 工具提示，每个 meter 一个区域，标题单独一行显示在文字上方。ToolTipIcon、ToolTipType 和
  ToolTipWidth 会被读取但不显示。隐藏的 meter、隐藏容器中的内容、点击穿透的皮肤或 ToolTipHidden=1 时没有工具提示。工具提示
  中的 `%1`、`%2`…… 在所有类型的 meter 上都使用手册规定的强制格式（AutoScale=1、不带小数）（取舍判断）。无论哪个 App
  在前台，工具提示都会显示：皮肤窗口允许在后台显示工具提示（否则 macOS 只在窗口所属的 App 处于活跃状态时才显示，而 Deskset
  作为菜单栏 App 几乎从不处于活跃状态）。鼠标停留半秒后显示，与 Windows 一致（AppKit 默认要等两三秒）。
- **原因：** macOS 的工具提示没有图标、气泡样式和宽度设置。
- **对皮肤的影响：** 工具提示与其他 Mac 工具提示外观相同。
- **状态：** 部分支持

### 7.3 菜单与管理窗口

#### 皮肤上下文菜单与自定义动作
- **Windows：** 皮肤名称、变体、设置（位置、透明度、悬停时隐藏、可拖动、点击穿透、保持在屏幕内、保存位置、吸附边缘……）、
  管理、编辑、刷新、卸载、自定义皮肤动作（`ContextTitleN` / `ContextActionN`，最多 25 个；超过 3 个时成为子菜单）。
- **Mac：** 皮肤名称、其自定义动作（规则相同；`!SkinCustomMenu` 只显示它们）、变体、位置、透明度、悬停、可拖动、点击穿透、
  保持在屏幕内、吸附边缘、保存位置、有提示时的“兼容性提示（n）”、管理皮肤…、编辑皮肤…（Skin Studio）、在“设置 ▸ 编辑器”
  里选了代码编辑器 App 时的“用 <App> 编辑”、刷新皮肤、打开皮肤文件夹、卸载皮肤。FadeDuration 和 Load Order 在管理窗口中设置；StartHidden 和 AutoSelectScreen 只能通过 `Default…` 选项
  和 bang 设置。
- **原因：** Mac 的菜单惯例。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 主菜单（托盘菜单）
- **Windows：** 通知区域图标的菜单；`!TrayMenu` 打开它。
- **Mac：** 菜单栏图标的菜单（管理皮肤…、皮肤、已加载的皮肤、全部刷新、安装皮肤…、打开皮肤文件夹、打开日志、登录时启动、
  关于、退出）；`!TrayMenu` 在指针处弹出它。macOS 可能会隐藏菜单栏图标（系统设置 → 菜单栏）：从访达、聚焦搜索或启动台再次
  打开 Deskset 会显示管理窗口，第一次启动时也会显示。再启动一个 Deskset 时，它会把要打开的文件交给正在运行的那个，然后退出。
- **原因：** macOS 允许用户隐藏菜单栏项目。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

### 7.4 配置与应用程序 bang

#### `!Refresh`、`!ActivateConfig`、`!DeactivateConfig` 和 `!ToggleConfig` 何时生效
- **Windows：** 手册没有说明动作执行过程中何时加载、卸载或刷新皮肤。
- **Mac：** 在 App 运行循环的下一轮，也就是发出请求的动作结束之后（在 OnRefreshAction 中刷新自己的皮肤，或两个互相刷新的皮肤，
  都不会无限递归）。同一动作中发给即将加载的配置的 bang 会等它加载完：`[!ActivateConfig X][!Move 10 10 X]` 会移动新加载的 X。
  皮肤不能在自己的 OnCloseAction 中重新加载或卸载自己。
- **原因：** 为稳健性所做的取舍判断。
- **对皮肤的影响：** 未观察到影响。
- **状态：** 模拟实现

#### 对已在运行该文件的配置执行 `!ActivateConfig`
- **Windows：** “激活一个皮肤”；不指定 File 时，“激活配置文件夹中的下一个 .ini 变体”。手册没有说明配置已经在运行该文件时
  会怎样；论坛上关于日志警告“already active”（已激活）的讨论表明，Rainmeter 会让该皮肤保持原样。
- **Mac：** 除了在日志中写一条警告外什么也不做。比较文件名时不区分大小写；配置文件夹中没有的文件会回退到上次使用的文件，
  对只有一个 .ini 文件的配置执行 `!ActivateConfig 配置` 得到的也是该文件，所以这两种情况同样不会动正在运行的皮肤。指定另一个
  变体时仍会替换正在运行的变体；`!Refresh`、`!ToggleConfig`、管理窗口和菜单不受影响。
- **原因：** 取舍判断。如果重新加载，激活自身配置的皮肤就会无休止地重新加载自己（Monstercat Visualizer 的更新提示在有新版本时
  每次加载都会这样做）。
- **对皮肤的影响：** 预计无；想重新加载自己的皮肤应使用 `!Refresh`。
- **状态：** 模拟实现（取舍判断）

#### `!RefreshApp` 与全部刷新
- **Windows：** 刷新 Rainmeter 和所有皮肤。
- **Mac：** 重新读取皮肤文件夹、重新解码图片、重新读取所有 `@Resources/Fonts` 文件夹，并刷新所有皮肤；App 本身不会重启。
- **原因：** —
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 布局（`!LoadLayout`）
- **Windows：** 布局用于保存和恢复一组已加载的皮肤及其设置。
- **Mac：** 皮肤包中的布局会被安装到 `~/Library/Application Support/Deskset/Layouts`，但暂时不能应用；`!LoadLayout` 会添加
  兼容性提示，要求加载布局的包会在安装后说明这一点。
- **原因：** 尚未实现。
- **对皮肤的影响：** 依靠布局完成设置的套件（Enigma、FluentDash11、Nelamint、Simple Clean、PogPack）需要在管理窗口中逐个
  加载皮肤。
- **状态：** 不支持

#### 其他宿主 bang
- **Windows：** `!SetClip`、`!SetWallpaper`、`!Play` / `!PlayLoop` / `!PlayStop`、`!Manage`、`!About`、`!EditSkin`、
  `!Quit`、`!ResetStats`、`!SetAnchor`。
- **Mac：** `!SetClip` 设置剪贴板；`!SetWallpaper` 为每块显示器设置墙纸（Tile 与 Center 一样按原尺寸显示——macOS 不能平铺）；
  `!Play` 一次播放一个声音；`!Manage` 打开管理窗口并定位到指定的配置；`!About Log` 打开日志；`!EditSkin` 在文本编辑器中打开
  文件；`!Quit` 在当前动作结束后退出。`!ResetStats` 和 `!SetAnchor` 不起作用，并添加兼容性提示。
- **原因：** 重启后不保留网络统计；尚未实现保存的锚点。
- **对皮肤的影响：** 受支持的 bang 没有影响。
- **状态：** 模拟实现 / 不支持（`!ResetStats`、`!SetAnchor`）

#### 运行程序和打开文件（`["…"]`）
- **Windows：** `["program.exe" args]` 运行程序；网址或文件用默认程序打开。
- **Mac：** 网址在默认浏览器中打开；存在的文件和文件夹用其默认 App 打开；如果目标是 Mac 的 `.app` 且参数是文件，就用它打开
  这些文件（皮肤在 `#CONFIGEDITOR#` 中打开设置文件就是这种方式），其他参数被丢弃。Mac 上不存在的 Windows 程序或路径不起
  作用，并记录日志（“不支持 Windows 程序”）。
- **原因：** `.exe` 文件无法在 macOS 上运行。
- **对皮肤的影响：** 指向 Windows 程序（Chrome、记事本、资源管理器路径）的启动器皮肤需要把目标改为 Mac App 或网址。
- **状态：** 部分支持

### 7.5 `Deskset --render`（供皮肤作者和测试使用）

#### 把皮肤渲染为 PNG
- **Windows：** 没有对应功能。
- **Mac：** `Deskset --render Skin.ini --out x.png [--updates N] [--interval ms] [--scale S] [--background R,G,B[,A]]
  [--skins-dir DIR]` 在没有窗口的情况下加载皮肤，执行 N 次更新（默认 2 次，间隔 1 000 ms），按比例 S（默认 2）绘制，并输出
  兼容性提示和日志行。窗口、配置和应用程序类 bang 被忽略，鼠标动作从不执行，也不会请求任何权限：不采集任何音频，因为只有
  皮肤窗口中的皮肤才会采集（`DESKSET_AUDIO_DEMO=1` 提供生成的信号），播放器显示为关闭
  （`DESKSET_NOWPLAYING_DEMO=1` 模拟一首正在播放的曲目）。图片中看不到 FrostedGlass 的模糊效果；WebParser 的 `file://` 只能
  读取皮肤文件夹和设置文件夹的限制（[§11.1](#111-webparser)）只在 App 中生效。`Deskset --help`（或 `-h`）列出所有命令行模式；
  无法识别的 `--` 选项会打印这份列表并以状态码 2 退出，而不会启动菜单栏 App。
- **原因：** 无需权限提示或可见屏幕即可得到可重复的截图。
- **对皮肤的影响：** 无（开发者工具）。
- **状态：** 仅 Mac

---

## 8. Lua 脚本

简而言之：`Measure=Script`、内联 Lua（`[&Script:Function()]`）以及完整的 SKIN / SELF / Measure / Meter API 都基于参考
实现 Lua 5.1.5（其源代码未经修改；少数库函数在运行时被移除或替换，见下文），脚本行为与 Windows 相同。差异在于安全限制、
Mac 路径以及少数在 Mac 上没有意义的函数。详细说明：[`compat/lua.md`](compat/lua.md)。

#### Lua 版本及每个 Script measure 独立的状态
- **Windows：** Lua 5.1；每个 Script measure 有自己的实例；全局变量不共享。
- **Mac：** 由未经修改的源代码构建的 Lua 5.1.5（下文所列被移除和受限的函数在运行时替换；模式匹配函数是 Lua 自身代码的修改版，
  加了递归上限）；每个 Script measure 一个 `lua_State`，加载时创建，刷新 / 卸载时关闭。
- **原因：** 语言版本相同。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 可用的库和被移除的函数
- **Windows：** 标准库，但去掉了 `require`、`os.exit`、`os.setlocale`、`io.popen`、`collectgarbage` 和外部编译库；
  `debug`、`setfenv`、`getfenv`、`coroutine` 可用。
- **Mac：** 同样移除上述函数，另外移除 `module` / `package` 库、`debug.sethook`、`newproxy`、`debug.getmetatable`、
  `debug.setmetatable`、`debug.getregistry`；`getmetatable(file)` 返回 `false`。
- **原因：** 这些函数可以把代码挂到垃圾回收上或去掉时间限制，从而让脚本冻结 App（取舍判断）。
- **对皮肤的影响：** 少数高级脚本会得到 “attempt to call a nil value” 错误（记录日志）。
- **状态：** 部分支持

#### 为内存安全而限制的函数
- **Windows：** 原版 Lua 5.1 完全信任脚本（`debug.setfenv`、`debug.setlocal`、`loadstring` 中的预编译字节码、没有上限的
  模式匹配递归）。
- **Mac：** `debug.getfenv` / `setfenv` 只作用于 Lua 函数和线程；`debug.setlocal` 不会改动 C 函数或隐藏的循环变量；
  `loadstring` / `load` / `dofile` / `loadfile` / ScriptFile 只接受文本（“binary (precompiled) chunks are not
  supported”）；字符串模式最多嵌套 200 层（“pattern too complex”），并受时间预算约束。
- **原因：** 下载来的皮肤绝不能让 App 崩溃，也不能在其中运行原生代码。
- **对皮肤的影响：** 对普通脚本没有影响；以预编译字节码形式发布的脚本无法运行。
- **状态：** 部分支持

#### ScriptFile
- **Windows：** 相对路径或完整路径；可以使用变量。
- **Mac：** 相同；处理 `\` 分隔符和大小写差异；超过 16 MB 或不是普通文件的不会读取；文件缺失时显示兼容性提示，数值为
  0 / “”。
- **原因：** 皮肤是在不区分大小写、使用 `\` 路径的 Windows 上编写的。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 脚本文件编码
- **Windows：** 要使用 Unicode，`.lua` 文件必须是 UTF-16；“绝不要把 .lua 脚本文件编码为 UTF-8”。
- **Mac：** 按 `.ini` 文件的方式解码（带或不带 BOM 的 UTF-8、UTF-16、UTF-32，否则按 ANSI），并以 UTF-8 交给 Lua；以 `#`
  开头的第一行被忽略。
- **原因：** 无论哪种方式 Lua 看到的都是 UTF-8；接受 UTF-8 属于宽松处理。
- **对皮肤的影响：** 在 Windows 上显示乱码的 UTF-8 脚本，在 Mac 上会显示为预期的文字。
- **状态：** 模拟实现

#### 与皮肤交换的文字
- **Windows：** Lua 一侧的字符串为 UTF-8。
- **Mac：** 相同；不是有效 UTF-8 的 Lua 字符串（例如从 ANSI 文件中读取的）按 Windows-1252 显示，而不是显示替换字符
  （取舍判断）。
- **原因：** ANSI 数据文件很常见。
- **对皮肤的影响：** ANSI 文件中带重音的拉丁字母能正确显示。
- **状态：** 完全一致

#### 主代码块与 `Initialize()`
- **Windows：** Initialize 在皮肤激活或刷新时运行一次，即使 measure 被禁用；全局作用域在初始化阶段运行；通过
  `!SetOption` 更换的 ScriptFile 也会调用其 Initialize。
- **Mac：** 主代码块在皮肤加载时运行；Initialize 在第一次更新中轮到该 Script measure 时运行（即使它被禁用、暂停或
  `UpdateDivider` 为负），如果 `!CommandMeasure` 先到达脚本则更早运行。加载期间发出的 bang 在 Initialize 之后立即执行。
- **原因：** 手册没有说明 Initialize 在第一次更新中的具体时机（取舍判断）。
- **对皮肤的影响：** 对在 Windows 上正常的皮肤没有影响。
- **状态：** 完全一致

#### `Update()` 与 measure 的值
- **Windows：** 可以不返回 / 返回数字 / 返回字符串 / 两者都返回；measure 遵循 Disabled、UpdateDivider 和 measure bang；
  出错时数值被重置；NumOfDecimals 等选项作用于绑定的 meter。
- **Mac：** 相同。返回的数字没有单独的字符串（由 meter 格式化；`[Script]` 最多显示 5 位小数，而不是 Lua 的 `%.14g`）；
  `true` / `false` 计为 1 / 0；table、函数和 nil 被忽略；运行时错误把数值重置为 0 和 “”。
- **原因：** 手册加上内联 Lua 对布尔值的规则。
- **对皮肤的影响：** 预计无。
- **状态：** 完全一致

#### Script measure 的 MinValue / MaxValue
- **Windows：** 无法得知自身范围的 measure 使用出现过的最小值和最大值。
- **Mac：** 除非设置了 MinValue / MaxValue，Script measure 也这样处理（取舍判断）。
- **原因：** 脚本无法声明自己的范围。
- **对皮肤的影响：** 绑定到没有 MaxValue 的脚本的 Bar，按出现过的最大值计算填充比例。
- **状态：** 模拟实现

#### 已弃用的 API（`PROPERTIES`、`GetStringValue()`、`GetValue()`、`tolua.cast`、`SetText`）
- **Windows：** 已弃用但仍受支持。
- **Mac：** 全部可用（`PROPERTIES` 从 measure 的选项填充；`Update()` 不返回值时由这些全局函数提供数值；`tolua.cast(x)`
  返回 `x`；`Meter:SetText(t)` 等同于 `!SetOption Meter Text t`）。
- **原因：** 让老脚本继续工作（对旧行为细节的取舍判断）。
- **对皮肤的影响：** 预计无。
- **状态：** 模拟实现

#### `SKIN:Bang()`
- **Windows：** bang 在“控制权从脚本返回时”执行；Lua 中不支持 `!Delay`。
- **Mac：** bang 进入队列，在最外层 Lua 调用返回后按顺序执行；每个参数保持完整；数字按 Lua 的格式，布尔值变为 1 / 0；单个
  字符串按动作执行（单独的网址或文件按 `["…"]` 处理）；单独的 `!Delay` 不起作用，写在动作字符串中则延迟该字符串的剩余
  部分；每次调用最多 10 000 个 bang / 32 MB。
- **原因：** 手册的时机规则；其余是为了让真实脚本正常工作。
- **对皮肤的影响：** 用 bang 设置某个值后立刻读取，读到的仍是旧值，与 Windows 相同。
- **状态：** 完全一致

#### `SKIN:GetVariable()`、`SKIN:MakePathAbsolute()` 与路径
- **Windows：** 路径是 Windows 路径（`C:\…\Skin\`），脚本常用 `path:match('([^\\]-)%.([^%.]+)$')` 之类的模式拆分路径。
- **Mac：** 交给脚本的路径（MakePathAbsolute 的结果，以及 `@`、`CURRENTPATH`、`ROOTCONFIGPATH`、`SKINSPATH`、
  `SETTINGSPATH`、`PROGRAMPATH`、`ADDONSPATH`、`PLUGINSPATH`，通过 `SKIN:ReplaceVariables` 取得时也一样）使用 `\` 分隔符
  （`\Users\me\Library\…\Skin\`）；嵌套写法 `[#@]` 以及用 `GetOption` 读取的选项值仍使用 `/`。脚本回传的任何路径都接受
  `\` 或 `/`。
- **原因：** 为 Windows 编写的路径拆分模式无需修改就能工作（取舍判断）。
- **对皮肤的影响：** 脚本显示的路径使用反斜杠，与 Windows 相同。为 Deskset 编写的脚本不应假定路径使用 `/`。
- **状态：** 模拟实现

#### `SKIN:GetX / GetY / GetW / GetH`、`MoveWindow`、`FadeWindow`
- **Windows：** 皮肤窗口的位置和尺寸；MoveWindow 移动窗口；FadeWindow 以 FadeDuration 的速度淡入淡出。
- **Mac：** 位置以点为单位，从主屏幕左上角算起（与 `!Move` 相同）；MoveWindow 执行 `!Move`；FadeWindow 把窗口设为 `from`，
  再在 FadeDuration 内渐变到 `to`（0…255），与脚本的 bang 按顺序执行。渐变后的值**不会**保存：它一直持续到皮肤刷新或再次设置
  AlphaValue（`!SetTransparency`、透明度菜单、管理窗口）为止；OnHover 和 `!Hide` / `!Show` 在其基础上生效。
- **原因：** macOS 使用点和翻转的 y 轴；手册没有说明渐变后的值是否保留，保持其为临时值就不会改动用户保存的设置。
- **对皮肤的影响：** 刷新后皮肤从保存的 AlphaValue 重新开始。
- **状态：** 模拟实现

#### `SKIN:ReplaceVariables()` 与 `SKIN:ParseFormula()`
- **Windows：** ReplaceVariables 也会替换节变量；ParseFormula 需要带括号的公式，否则返回 nil。
- **Mac：** 相同；ParseFormula 还会先替换变量，并接受 measure 名称；无效输入返回 nil。
- **原因：** 宽松处理。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### Measure 对象（`SKIN:GetMeasure`、`SELF`）
- **Windows：** GetValue、GetStringValue、GetRelativeValue、GetValueRange、GetMinValue、GetMaxValue、GetOption、
  GetNumberOption、GetName、Disable、Enable。
- **Mac：** 全部可用；GetStringValue 是经过 Substitute 之后的值；GetOption 能看到 `!SetOption` 设置的值；Disable / Enable
  立即生效；用 `.` 而不是 `:` 调用方法会给出清楚的错误信息。
- **原因：** 手册（对 nil 默认值的取舍判断）。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### Meter 对象（`SKIN:GetMeter`）
- **Windows：** GetOption、GetName、GetX(Absolute)、GetY(Absolute)、GetW、GetH、SetX…SetH、Hide、Show。
- **Mac：** 全部可用。GetX() / GetY() 返回相对于 meter 所在容器的位置（普通 meter 即皮肤），GetX(true) 返回在皮肤中的
  位置；GetW / GetH 包含 Padding，隐藏的 meter 为 0；SetX…SetH 立即生效。在第一次更新结束之前（主代码块、Initialize、
  第一次 Update），第一次 Get / Set 调用会根据 meter 的选项计算临时布局（见
  [第一次更新之前的 meter 几何信息](#第一次更新之前的-meter-几何信息)）。
- **原因：** 手册没有定义 `r` / `R` meter 的非绝对位置（取舍判断）。
- **对皮肤的影响：** 期望 GetX() 返回 `r` 偏移量的脚本得到的是位置；绑定 measure 的 String meter 只有在第一次更新之后才有
  真实宽度（请在之后的 Update() 中再次读取）。
- **状态：** 模拟实现

#### `print()`
- **Windows：** 写入日志。
- **Mac：** 以 Notice 级别写入皮肤日志；每个脚本每秒最多 100 行；超过 2000 个字符的行会被截断。
- **原因：** 高频 Update 中的 print 不能把日志刷屏。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### `!CommandMeasure` 与内联 Lua
- **Windows：** `!CommandMeasure` 在某个脚本实例中运行 Lua 代码；`[&Script:Function(args)]` 调用函数（在选项中需要
  DynamicVariables=1；bang 中总是会解析）。
- **Mac：** 相同；命令对禁用和暂停的 Script measure 也有效。在没有 DynamicVariables 的选项中，`[&Script:…]` 与所有节变量一样
  在第一次更新时解析一次。内联 Lua：返回 nil 得到 “”（记录日志）；返回 table / 函数、
  函数不存在或出错时文字保持未解析（记录日志）；接受更多参数写法（字符串中的撇号、带反斜杠的 Windows 路径、Lua 表达式）。
- **原因：** 手册；宽松处理属于取舍判断。
- **对皮肤的影响：** 预计无。
- **状态：** 完全一致

#### `io` 路径与文本模式
- **Windows：** Windows 路径，相对于工作目录；文本模式会把 “\r\n” 转换为 “\n”。
- **Mac：** `\` 或 `/` 都可以；相对路径从皮肤文件夹算起；已存在的文件不区分大小写查找；以文本模式读取时把 “\r\n” 转换为
  “\n”；标准输入读不到任何内容。
- **原因：** macOS 没有文本模式；App 的工作目录是 `/`。
- **对皮肤的影响：** CRLF 数据文件和 Windows 路径可以使用。读取桌面、文稿或下载文件夹可能会弹出 macOS 隐私提示；如果被
  拒绝，`io.open` 返回 nil 和错误信息。
- **状态：** 模拟实现

#### `dofile` / `loadfile`
- **Windows：** “必须指定完整路径”。
- **Mac：** 文件按脚本文件的方式解码；相对路径从皮肤文件夹算起；没有文件名时报错 / 返回 nil，而不是读取标准输入。
- **原因：** 与 ScriptFile 保持一致。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### `os.execute`
- **Windows：** 通过 cmd.exe 运行命令；皮肤大多用 `os.execute('start "" "https://…"')`。
- **Mac：** 不运行任何 shell 命令。`start …`、`cmd /c start …`、`open target` 以及单独的网址或存在的文件会打开目标（返回
  0）。其他命令返回 1，并记录一次日志。
- **原因：** Windows 命令对 `/bin/sh` 没有意义，而阻塞的命令会冻结皮肤。
- **对皮肤的影响：** 只负责打开东西的命令可以用；其他命令静默地不起作用。真正的命令行请用 RunCommand。
- **状态：** 部分支持

#### `os.getenv`
- **Windows：** Windows 环境变量。
- **Mac：** 先查真实的环境变量；然后 USERNAME → USER，USERPROFILE / HOMEPATH → HOME，HOMEDRIVE → “”，APPDATA /
  LOCALAPPDATA → `~/Library/Application Support`，TEMP / TMP → 临时文件夹，PROGRAMFILES → `/Applications`；其他名称为 nil。
- **原因：** 脚本用它们拼接路径。
- **对皮肤的影响：** 这些路径指向 Mac 上对应的位置。
- **状态：** 模拟实现

#### `os.date`、`os.clock` 及其他 `os` 函数
- **Windows：** 微软 C 库（`%#d` 去掉前导零；`clock()` 是挂钟时间）。
- **Mac：** 模拟了 `%#x` 标志；`os.clock` 返回挂钟秒数（Mac 的 C 库会返回 CPU 时间）；`math.random` 的序列不同。
- **原因：** 脚本用 `os.clock` 为动画计时。
- **对皮肤的影响：** 预计无。
- **状态：** 模拟实现

#### 错误信息
- **Windows：** 记录在“关于”窗口中。
- **Mac：** 记录为 `[Measure] Script: Root/Sub/File.lua:12: message`；每个脚本每条不同的消息只记录一次（最多 100 条），
  超过 2000 个字符会截断。
- **原因：** 控制日志量。
- **对皮肤的影响：** 重复出现的错误只显示一次。
- **状态：** 模拟实现

#### 失控的脚本与内存
- **Windows：** 没有写明（死循环会冻结 Rainmeter）。
- **Mac：** 每次最外层调用最多执行 2 亿条指令、运行 2 秒；被停止的调用抛出 `pcall` 无法捕获的 “script stopped after …
  (endless loop?)”；连续停止 3 次后，脚本在刷新前不再运行（显示兼容性提示）。每个脚本 64 MB，所有脚本合计 512 MB；嵌套
  调用最多 32 层。
- **原因：** 皮肤绝不能让 App 卡死或崩溃。
- **对皮肤的影响：** 正常脚本远低于这些限制。
- **状态：** 模拟实现

#### 线程
- **Windows：** 脚本在皮肤的线程上运行。
- **Mac：** 脚本在更新皮肤的线程（主线程）上同步运行。
- **原因：** 皮肤不是线程安全的。
- **对皮肤的影响：** 网络卷上缓慢的 `io` 会阻塞皮肤，与 Windows 相同。
- **状态：** 完全一致

---

## 9. 内置插件（核心）

不需要 Apple 界面或媒体框架的 Rainmeter 插件：ActionTimer、CoreTemp、SpeedFan、AdvancedCPU、UsageMonitor、PerfMon、Ping、
RunCommand、Quote、FolderInfo、FileView、RecycleManager、ResMon、WindowMessage 和 VirtualDesktops，以及第三方的 Mouse 插件
（§9.8）和它的第 2 版 Slider（§9.9）。详细说明：[`compat/plugins.md`](compat/plugins.md)。

### 9.1 通用

#### 插件名称与别名
- **Windows：** `Measure=Plugin` + `Plugin=Name`、`Name.dll` 或 `Plugins\Name.dll`；RecycleManager 也可以作为 measure 使用。
- **Mac：** 所有写法都接受，不区分大小写，包括 `PingPlugin` / `Ping`、`QuotePlugin` / `Quote`、`PerfMon` /
  `PerfMonPlugin`、`SpeedFanPlugin` / `SpeedFan`、`WindowMessagePlugin` / `WindowMessage`。
- **原因：** 老皮肤各种写法都有。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 插件 measure 的范围（MinValue / MaxValue）
- **Windows：** 无法得知最大值的 measure 使用出现过的最小值和最大值；CoreTemp 和 SpeedFan 的页面说要显示百分比“必须加上”
  MinValue / MaxValue。
- **Mac：** 除非设置了 MinValue / MaxValue，每个数值会变化的核心插件 measure（CoreTemp、SpeedFan、AdvancedCPU、
  UsageMonitor、PerfMon、ResMon、Ping、RunCommand、FolderInfo、FileView、RecycleManager）都会跟踪出现过的范围；ActionTimer、
  Quote、WindowMessage、VirtualDesktops、Mouse 和 Slider 保持固定的 0…1 范围。
- **原因：** 手册对插件 measure 的总体描述。
- **对皮肤的影响：** 没有 MaxValue 的进度条按出现过的最大值缩放，与 Windows 相同。
- **状态：** 完全一致

#### 后台工作与卸载
- **Windows：** 插件在自己的线程中工作；RunCommand 在刷新 / 卸载时结束隐藏运行的程序。
- **Mac：** ping、命令、文件夹扫描、废纸篓和逐进程采样都在后台运行，再把结果交给皮肤（数值在插件的 FinishAction 执行前
  设置好）。刷新 / 卸载时停止计时器、取消 ping、结束隐藏运行的 RunCommand 程序。
- **原因：** 任何东西都不能阻塞皮肤。
- **对皮肤的影响：** 后台得到的值在下一次更新或 FinishAction 执行时出现。
- **状态：** 模拟实现

#### 插件选项中的 Windows 路径
- **Windows：** Path / PathName / Folder / StartInFolder / OutputFile / IconPath 使用 Windows 路径。
- **Mac：** `\` 变为 `/`；`%USERPROFILE%`、`%HOMEDRIVE%%HOMEPATH%` → 个人文件夹；`%APPDATA%` / `%LOCALAPPDATA%` →
  `~/Library/Application Support`；`%TEMP%` → 临时文件夹；`%PUBLIC%` → `/Users/Shared`；`%PROGRAMFILES%` →
  `/Applications`；`%PROGRAMDATA%` → `/Library/Application Support`；`%WINDIR%` → `/System`；`C:\Users\<任意用户>\X` →
  `~/X`（Videos → Movies，My Pictures → Pictures……）；其他带盘符的路径 → `/` 下的同名路径；相对路径从皮肤文件夹算起。
- **原因：** Mac 没有盘符，个人文件夹的结构也不同（取舍判断）。
- **对皮肤的影响：** `%USERPROFILE%\Pictures` 的相册、文稿中的便笺等可以使用；指向其他盘的路径通常不存在。
- **状态：** 模拟实现

#### 隐私提示
- **Windows：** 没有提示。
- **Mac：** 读取桌面、文稿、下载、可移除卷或网络卷（Quote、FolderInfo、FileView）会询问一次；控制访达（RecycleManager
  清空、FileView 显示简介）会询问一次自动化权限；RecycleManager 的 `Size` 需要完全磁盘访问权限（没有弹窗；缺少时会有一条
  兼容性提示）。被拒绝时数值为空 / 不执行操作，并记录一次日志。
- **原因：** macOS 的隐私保护。
- **对皮肤的影响：** 出现一次系统对话框（[§4](#4-macos-权限)）。
- **状态：** 模拟实现

### 9.2 ActionTimer

#### ActionList、Wait、Repeat、Execute、Stop
- **Windows：** `ActionListN=Action | Wait ms | Repeat Action, ms, count`；Execute 启动列表，Stop 停止；正在运行的列表会
  忽略 Execute。
- **Mac：** 语义完全相同；多个列表并行运行；列表的最后一个动作开始时即视为结束，因此该动作可以再次 `Execute` 同一个列表
  （循环动画的常用写法）。
- **原因：** —
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### 计时
- **Windows：** “尽可能快”，只由 Wait 控制节奏。
- **Mac：** 各步骤在主运行循环上执行（菜单打开时也会执行）；每个 Wait 从上一步计划的时间算起（没有漂移）；某一步延迟超过
  100 ms 时重新从“现在”开始计时，而不是一口气补发错过的步骤；每轮运行循环最多执行 64 个动作；次数上限 1000 万，等待上限
  24 小时。
- **原因：** 绘制必须在主线程进行；无漂移调度。
- **对皮肤的影响：** 动画至少同样流畅。
- **状态：** 模拟实现

#### 动作中的变量及其他细节
- **Windows：** 动作与其他动作选项一样；要使用改过的 `#Variables#` 需要 `!UpdateMeasure`。
- **Mac：** 相同；`[节变量]` 在每个动作执行时解析；measure 被禁用或暂停时命令仍然有效；未定义的列表会记录日志；数值为 0。
- **原因：** 手册未作规定时的取舍判断。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

### 9.3 硬件传感器：CoreTemp 与 SpeedFan

#### CoreTemp
- **Windows：** 读取必须在运行的 Core Temp 程序。
- **Mac：** 数值来自 Mac 本身：`Load` = 各核心 CPU 使用率（序号从 0 开始）；`CpuName` = 处理器名称（“Apple M4 Pro”）；
  `CpuSpeed` / `CoreSpeed` = macOS 报告的 MHz（Intel），否则为 0；`Temperature`、`MaxTemperature`（默认）、`TjMax`、`Vid`、
  `Tdp`、`Power` 在支持传感器之前为 0；Apple 芯片上总线相关数值为 0。始终使用摄氏度。
- **原因：** macOS 没有公开的温度 / 电压 API（SMC 键因芯片而异，且需要特权）。
- **对皮肤的影响：** 负载条和 CPU 名称可用；温度为 0（记录一次日志）。
- **状态：** 部分支持

#### SpeedFan
- **Windows：** 读取 SpeedFan 程序（温度、风扇、电压）。
- **Mac：** 选项相同，但在支持硬件传感器之前数值为 0（记录一次日志）。
- **原因：** 没有 SpeedFan，也没有公开的传感器 API。
- **对皮肤的影响：** 风扇 / 温度显示为 0。
- **状态：** 部分支持

### 9.4 进程与性能计数器

#### AdvancedCPU（已弃用）
- **Windows：** 按核心数缩放的进程 CPU 时间；`TopProcess`、`CPUInclude` / `CPUExclude`。
- **Mac：** 自上次更新以来使用的 CPU 时间，以 100 ns 为单位（与 Windows 计数器相同），因此皮肤自己的百分比计算可以照用；
  `Idle` = 所有核心的空闲时间；其他用户的进程（WindowServer、kernel_task、各种守护进程）合并为一个名为 `System` 的进程；
  名称是 Mac 可执行文件名；列表中忽略 `.exe`；`Rainmeter` 表示 Deskset；每秒在后台采样一次。
- **原因：** macOS 隐藏其他用户进程的详细信息；主线程上不能做阻塞工作。
- **对皮肤的影响：** “System” 可能出现在占用最高的进程中（用 `CPUExclude=Idle;System` 排除）；列出 Windows 程序名的列表
  匹配不到任何进程；数值在前两次采样之后出现。
- **状态：** 模拟实现

#### UsageMonitor
- **Windows：** 任意性能监视器的类别 / 计数器 / 实例，或别名（CPU、RAM、IO、GPU、VRAM……）。
- **Mac：** 模拟了常用计数器：进程（`% Processor Time`、`Working Set - Private`、`Private Bytes`、`Virtual Bytes`、
  `Thread Count`、`ID Process`、IO 字节 / 秒……）、处理器（各核心时间）、内存（`Available Bytes`、`Committed Bytes`、
  `Commit Limit`……）、分页文件、网络接口（字节 / 秒）、逻辑磁盘 / 物理磁盘（可用空间、字节 / 秒）、系统（进程数、线程数、
  开机时长、负载）。Index、Name、Blacklist / Whitelist、Rollup、Percent、RawValue 和 PIDToName 按手册处理（名称还可以不区分
  大小写、不带 `.exe` 匹配）。GPU 计数器需要传感器支持；其他计数器为 0，并作为兼容性提示列出。
- **原因：** macOS 没有性能监视器；这些是 Darwin 上的对应数据。
- **对皮肤的影响：** 占用排行、各核心负载、网络和内存计数器可用；GPU 和冷门计数器为 0。
- **状态：** 部分支持

#### PerfMon（已弃用）
- **Windows：** `PerfMonObject` / `Counter` / `Instance`，可带 `PerfMonDifference`。
- **Mac：** 与 UsageMonitor 相同的计数器，以原始值报告（PerfMonDifference=1 时为自上次更新以来的变化；处理器的
  `% Processor Time` 是反向计时器，符合皮肤的预期）。未知的网卡名表示所有接口。
- **原因：** 根据手册描述的取舍判断。
- **对皮肤的影响：** 各核心图表（PogPack）可用；未知计数器（例如 `Current Bandwidth`）为 0。
- **状态：** 部分支持

#### ResMon
- **Windows：** GDI、USER、Handle 和 Window 数量，可限定为某个进程。
- **Mac：** `Handle` = 打开的文件描述符数（指定名称的进程，否则为整个系统）；GDI、USER 和 Window 为 0。
- **原因：** macOS 没有 GDI / USER 对象。
- **对皮肤的影响：** GDI / USER 显示为 0。
- **状态：** 部分支持

### 9.5 Ping 与 RunCommand

#### Ping
- **Windows：** 到 `DestAddress` 的往返时间；`UpdateRate`、`Timeout`、`TimeoutValue`、`FinishAction`。
- **Mac：** 在后台线程发送无需特权的 ICMP echo（优先 IPv4）；第一次更新时以及此后每 UpdateRate 次更新 ping 一次；以整毫秒
  计；收到第一次回复前为 0。无法解析的名称和发送错误按超时处理；DestAddress 为空时不 ping。
- **原因：** macOS 允许不需要 root 权限的 ICMP echo。
- **对皮肤的影响：** 无；离线时显示 TimeoutValue。
- **状态：** 完全一致

#### RunCommand：命令如何运行
- **Windows：** `Program`（默认 cmd.exe）+ `Parameter`，隐藏运行，捕获标准输出。
- **Mac：** 命令行通过 `/bin/sh -c` 在皮肤文件夹中运行，PATH 包含 Homebrew，使用 UTF-8 区域设置。Program 为空或为
  `cmd.exe` 时表示“Parameter 就是命令行”；Mac 程序（`python3`、`osascript`）会把 Parameter 附加在后面。引号、转义和重定向
  原样传给 shell。
- **原因：** POSIX 命令就是 Mac 的命令行程序。
- **对皮肤的影响：** 通用命令（`curl …`、`echo`、`whoami`、`hostname`）无需修改即可使用。
- **状态：** 模拟实现

#### RunCommand：Windows 专属命令
- **Windows：** 任何 Windows 程序或 cmd.exe 命令。
- **Mac：** 以下命令从不交给 shell：PowerShell、wscript / cscript、mshta、rundll32、没有 Mac 对应物的 cmd 内置命令
  （`dir`、`copy`、`del`、`tasklist`、`wmic`、`reg`、`netsh`……）、以 `.exe`、`.bat`、`.cmd`、`.ps1`、`.vbs` 等结尾的程序、
  含 cmd.exe 变量的命令行、带盘符或 UNC 的路径。它们在任何东西启动前就以错误 103 失败。同名命令（`find`、`sort`、`date`、
  `ping`、`for`……）会通过 shell 运行，除非使用了 Windows 语法（`/开关`）。会做转换的：`start` / `explorer 目标` →
  `open 目标`；Windows 的 `ping -n N` → `ping -c N`；`type 文件` → `cat 文件`；cmd 的 `&` 分隔符 → `;`；`2>nul` →
  `/dev/null`。
- **原因：** 把 Windows 命令行放到另一种 shell 中运行，可能做出作者意料之外的事。
- **对皮肤的影响：** 基于 PowerShell / WMIC 的信息皮肤不显示内容（错误 103）；通用和 Mac 命令行可用。
- **状态：** 部分支持

#### RunCommand：启动失败后的 FinishAction
- **Windows：** FinishAction 在程序结束时执行；103 表示“无法启动程序”。
- **Mac：** 出现错误 103 后仍会执行 FinishAction，让等待它的皮肤继续下去（同一 measure 在一秒内再次失败时除外，以免循环）。
  取舍判断。
- **原因：** 对 Windows 专属命令做优雅降级。
- **对皮肤的影响：** 得到空结果，而不是一直等待。
- **状态：** 模拟实现

#### RunCommand：数值、错误码、State、Close、Kill、Timeout、输出
- **Windows：** 首次运行前 -1，运行中 0，成功 1，100–106 为错误；`State` 为 Hide / Show / Minimized / Maximized；Close /
  Kill；OutputType 为 UTF16 / UTF8 / ANSI。
- **Mac：** 错误码相同；退出状态不影响结果；标准错误被丢弃（`2>&1` 可保留）；输出最多 16 MB。命令行程序没有窗口，所以
  `State` 只决定刷新时是否结束程序（Hide，默认）。Close = SIGTERM，Kill = SIGKILL；忽略 Close 超过一秒的程序不再等待。不论
  OutputType 如何，输出都按 UTF-8 读取；OutputFile 按 OutputType 指定的编码写入。
- **原因：** Mac 上没有控制台窗口；Mac 程序输出 UTF-8。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

### 9.6 文件与文件夹

#### QuotePlugin
- **Windows：** 随机取文件中的一段（按 `Separator` 分割），或文件夹中的一个随机文件（`Subfolders`、`FileFilter`）。
- **Mac：** 相同；每次更新换一个随机项，且不会连续两次相同；跳过隐藏文件和访达文件；文件按皮肤文件的方式解码；文件夹在后台
  读取（超过一分钟会重新读取）；最多 100 000 项。
- **原因：** 主线程上不做文件 I/O。
- **对皮肤的影响：** 加载后数值会短暂为空。
- **状态：** 完全一致

#### FolderInfo
- **Windows：** FileCount / FolderCount / FolderSize，支持 RegExpFilter、子文件夹、隐藏和系统文件。
- **Mac：** 选项相同；隐藏 = 以点开头的文件和带隐藏标志的文件；系统 = 访达的记录文件（`.DS_Store`、`._*`……）；包（`.app`）
  算作文件夹；不跟随链接；在后台扫描（扫描慢的文件夹会降低扫描频率）；最多 200 万项。
- **原因：** Mac 的文件属性；主线程上不做 I/O。
- **对皮肤的影响：** 计数可能与资源管理器略有不同；大文件夹不会冻结皮肤。
- **状态：** 模拟实现

#### FileView
- **Windows：** 父 measure 列出一个文件夹（默认“此电脑”）；子 measure 按 Index 读取项目；命令 FollowPath、Open、
  PreviousFolder、ContextMenu、Properties；Type=Icon 写出 `.ico` 文件。
- **Mac：** 模型相同；默认路径为 `/Volumes/`（已装载的卷）；排序与访达类似（`..`、文件夹、文件；自然排序）；FileDate 使用
  用户的区域格式；路径使用 `/`。`Type=Icon` 在后台按 IconSize 写出访达的图标：路径为 `.ico` 且不超过 256 像素时是真正的
  `.ico` 文件，否则写入 PNG 数据（Image meter 两者都能读取），IconPath 中缺少的文件夹会被创建。ContextMenu 在访达中显示该
  项目（无法显示另一个 App 中访达的上下文菜单）；Properties 打开访达的“显示简介”窗口（需要自动化权限）。
- **原因：** macOS 的路径和 API。
- **对皮肤的影响：** 右键菜单变为“在访达中显示”；从路径中解析 `\` 的皮肤需要改用 `/`。
- **状态：** 部分支持

#### RecycleManager
- **Windows：** 回收站的 `Count` / `Size`；OpenBin、EmptyBin、EmptyBinSilent。
- **Mac：** 废纸篓（`~/.Trash` 加上其他内置卷的废纸篓）。Count 不需要权限；Size 需要完全磁盘访问权限（否则为 0，兼容性提示
  和日志会说明在哪里授权；能读取大小后提示消失）。OpenBin 在访达中打开废纸篓；EmptyBin 通过访达自己的确认对话框清空，
  EmptyBinSilent 不确认直接清空（需要访达的自动化权限）。旧的 `Drives=` 选项被忽略。
- **原因：** macOS 保护废纸篓的内容；废纸篓归访达管理。
- **对皮肤的影响：** 项目数可用；显示大小的皮肤在授予完全磁盘访问权限前显示 0。
- **状态：** 部分支持

### 9.7 在 macOS 上没有对应物

#### WindowMessage
- **Windows：** 向其他程序的窗口发送窗口消息，并返回结果或窗口标题。
- **Mac：** 数值为 0，字符串为 “”，命令被忽略（记录一次日志）。
- **原因：** macOS 没有窗口消息；读取其他 App 的窗口标题需要屏幕录制权限。
- **对皮肤的影响：** Winamp 风格的控制按钮不起作用。
- **状态：** 不支持

#### VirtualDesktops
- **Windows：** 用于 Dexpot / VirtuaWin 桌面管理器的插件。
- **Mac：** 只报告一个桌面（数量 1、当前 1、名称 “Desktop 1”）；命令被忽略。
- **原因：** macOS 的“空间”没有公开 API。
- **对皮肤的影响：** 桌面切换器只显示一个桌面。
- **状态：** 不支持

### 9.8 Mouse（第三方：拖动滑块）

#### 动作、`$MouseX$` / `$MouseY$`、RelativeToSkin
- **Windows：** 插件执行所有鼠标动作选项，而且“不限于某个 meter”；另外还有 `MouseMoveAction` 和 `LeftMouseDragAction` …
  `X2MouseDragAction`（在移动动作之后执行）；`$MouseX$` / `$MouseY$` 相对于皮肤，设置 `RelativeToSkin=0` 时相对于
  “显示器的左上角”。
- **Mac：** 同样的动作：五个按键的 Down / Up / DoubleClick、滚轮动作、MouseMoveAction（也接受 `MoveAction`）、拖动动作，
  以及指针移到皮肤上 / 离开皮肤时的 MouseOverAction / MouseLeaveAction。双击先执行 DoubleClick 动作，再执行 Down 动作。
  RelativeToSkin=0 时是以主屏幕左上角为原点的屏幕坐标；`$MouseX:%$` / `$MouseY:%$` 不会被替换。数值为 0。
- **原因：** 悬停动作（“所有动作选项”）和“显示器”的含义属于取舍判断。
- **对皮肤的影响：** 预计没有。
- **状态：** 完全一致

#### 输入从哪里来，以及执行顺序
- **Windows：** 3.2 版只看 Rainmeter 自己窗口的鼠标输入（更早的版本使用全局鼠标钩子）；论坛帖子说，没有
  RequireDragging 时，指针一离开皮肤，拖动就不再传给插件。插件动作和皮肤自身鼠标动作的先后顺序没有文档说明。
- **Mac：** 皮肤窗口自己的输入。在皮肤上开始的按下会一直跟随到按键松开，指针在皮肤外也一样；在别处开始的按下永远不算
  拖动；按住 ⌘ 的按下和 Control-点按不会传给插件；丢失的松开会在下一次移动时补报。Mouse measure 先于 meter 收到每个事件。
- **原因：** macOS 会把一次按下的拖动和松开交给按下时所在的窗口；丢掉松开会让皮肤停在拖动到一半的状态。
- **对皮肤的影响：** 指针越过皮肤边界后滑块仍然跟随。meter 的 LeftMouseDownAction 启用或启动这个 measure 时，这一次按下
  不会执行 measure 自己的 LeftMouseDownAction。
- **状态：** 模拟实现

#### RequireDragging、Start 与 Stop；禁用与暂停
- **Windows：** 设置 `RequireDragging=1` 后，插件接受 `!CommandMeasure … "Start"` / `"Stop"`，“让鼠标捕获也发生在边界
  之外”；没有这个选项时，要暂停或禁用这个 measure，它必须有 DynamicVariables=1 并且被更新。
- **Mac：** RequireDragging=1 时，动作只在 Start 和 Stop 之间执行（measure 被禁用或暂停时命令也有效）；没有这个选项时，
  Start / Stop 被忽略，并记录一条警告。禁用或暂停会立即停止动作；启用不需要更新就生效（按文档更新一次也可以）。
- **原因：** 取舍判断——公开的皮肤都从被拖动的 meter 启动这个 measure、在松开时停止；每个滑块各用一个 measure 的皮肤依赖
  只有被启动的那一个作出反应。
- **对皮肤的影响：** 预计没有。
- **状态：** 模拟实现

#### UpdateRate 与旧版本的选项
- **Windows：** 3.0 版的文档有 `UpdateRate`（默认 20），即“执行插件的移动和拖动动作的间隔（毫秒）”，还有 `NeedsFocus`；
  后来的版本都去掉了。2.x 版是一个名为 Slider 的插件。
- **Mac：** 移动和拖动动作每 UpdateRate 毫秒最多执行一次（0 = 每次移动都执行）；等待中的最新位置在间隔结束时执行，或者
  在这个 measure 的下一个其他动作之前执行，所以松开总在最终的拖动位置之后。NeedsFocus 被忽略；`Plugin=Slider` 是一个
  单独的 measure（§9.9）。
- **原因：** 文档所述的含义；也能减轻每次移动都写文件的拖动动作的负担。
- **对皮肤的影响：** 默认情况下，移动 / 拖动动作每秒最多执行 50 次。设置了 NeedsFocus=1 的 measure 在它的皮肤没有焦点时
  也会执行动作。
- **状态：** 部分支持

### 9.9 Slider（第三方：Mouse 插件的第 2 版）

#### 选项与动作
- **Windows：** `MouseButton`（Left、Right 或 Middle）选择要跟踪的按键；按下 / 松开时执行 `ClickAction` / `ReleaseAction`，
  按住并移动鼠标时执行 `DragAction`，按住 `HoldDelay` 毫秒（默认 300）后执行 `HoldAction`，鼠标移动时执行
  `MoveAction`。`$MouseX$` / `$MouseY$` 和 `RelativeToSkin` 与 Mouse 插件相同。
- **Mac：** 同样的选项和动作。MouseButton 不区分大小写（其他值一律当作左键，并记录一条警告）；拖动时也执行 MoveAction，
  并且在 DragAction 之前；双击就是再按一次。不读取第 3 版的选项和文档里没有的选项（`MoveDelay`），也没有任何命令。
  数值为 0。
- **原因：** 拖动时的 MoveAction 和其他 MouseButton 值属于取舍判断。
- **对皮肤的影响：** 预计没有。设置 MouseButton=Right 时，右键点按仍会打开皮肤菜单，除非 meter 的右键动作阻止了它。
- **状态：** 完全一致

#### 能收到哪些输入
- **Windows：** 文档没有直接说明；第 2 版在自己的线程里观察鼠标，3.2 版的发布说明写的是改用进程内钩子、不再使用全局钩子，
  可见第 2 版观察的是整个屏幕上的鼠标。公开的皮肤也假定能收到屏幕上任何地方的点击（Keystrokes 的鼠标按键显示；VisBubble
  的设置窗口靠这些点击关闭弹出菜单）。
- **Mac：** 在皮肤上，与 Mouse 插件相同的输入（§9.8）：按下被跟踪的按键后一直跟随到按键松开，指针在皮肤外也一样；以及指针
  在皮肤上的移动。在屏幕上的其他地方——其他 App、桌面、皮肤的透明部分、隐藏或点击穿透的皮肤、Deskset 自己的其他窗口（另一个
  皮肤、皮肤编辑器、管理窗口）——同样执行这些动作：被跟踪按键的 Click / Release，在那里按下后的 Drag 和 Hold，每一次移动
  和拖动的 MoveAction；这时 `$MouseX$` / `$MouseY$` 在皮肤之外（RelativeToSkin=0 时为屏幕坐标，任何一块屏幕都一样）。皮肤
  自己的窗口收到的点击绝不会报告两次；来自其他地方的输入只交给 Slider measure，按文件顺序。在其他地方按住 Control 点按算作按下左键。
- **原因：** 取舍判断——3.2 版之前的版本观察整个屏幕，为第 2 版写的皮肤依赖这一点。
- **对皮肤的影响：** 预计没有：Keystrokes 会显示每一次点击，VisBubble 在别处点击时会关闭弹出菜单。
- **状态：** 模拟实现

#### 观察屏幕上其他地方的鼠标
- **Windows：** 钩子或轮询线程；不需要用户做任何授权。
- **Mac：** 使用 AppKit 的事件监视器（其他 App 的事件；Deskset 自己窗口的事件），只观察鼠标事件：不需要任何权限（只有按键事件
  才需要辅助功能权限，而按键从不观察）。只有当已加载的皮肤里有启用且未暂停、其动作确实需要的 Slider measure 时才会安装监视器，
  也只观察这些动作需要的内容（按键的按下与松开；Drag / Hold 需要的拖动，只在别处按下的该键仍按着时；MoveAction 需要的
  每一次移动）；一旦不再有这样的 measure（被禁用、皮肤卸载、刷新后不再需要、退出 App）就立即移除。预览、`--render` 和自测
  从不观察鼠标。输入在 macOS 报告后立即在主线程交给皮肤；移动和拖动动作保持 20 毫秒冷却。在 Deskset 自己的窗口里按下时，
  每 20 毫秒读取一次指针，直到按键松开（这些窗口的控件会先拿走拖动和松开事件）。
- **原因：** macOS 没有不需要辅助功能权限的全局鼠标钩子；事件监视器不需要权限。
- **对皮肤的影响：** 看不到在 Deskset 自己的菜单里的点击，也可能漏掉指针在 Deskset 的非皮肤窗口上的移动。设置了 MoveAction
  时，鼠标在任何地方移动都会执行它（每秒最多 50 次）。
- **状态：** 模拟实现

#### HoldAction、20 毫秒冷却、禁用与暂停
- **Windows：** 按键“按住一段时间”后执行 HoldAction；2.0.0.24 版“带 20 毫秒冷却”运行。文档没有更多说明。
- **Mac：** 每次按下最多执行一次按住动作：HoldDelay 过后按键仍按着时执行，使用指针当时的位置；在此之前松开就不再执行。
  移动和拖动动作最多每 20 毫秒执行一次，等待中的位置会在松开或按住动作之前执行。禁用与暂停与 Mouse 插件相同：被按下的
  meter 启用的 measure（NXT-OS 的滚动条）会继续处理这一次按下的拖动和松开，但不会为它执行 ClickAction。禁用或暂停的
  measure 不观察其他地方的鼠标：在此期间于别处按下的按键，重新启用后也不会跟随。
- **原因：** 取舍判断——文档没有更多说明。
- **对皮肤的影响：** 移动 / 拖动动作每秒最多执行 50 次；最后的位置不会丢失。
- **状态：** 模拟实现

---

## 10. 音频、媒体、网络与界面插件

这些插件基于 Core Audio、AppleScript（Music / Spotify）、CoreWLAN 和 AppKit 重新实现。详细说明：
[`compat/audio.md`](compat/audio.md) 和 [`compat/media-ui.md`](compat/media-ui.md)。权限汇总见 [§4](#4-macos-权限)。

### 10.1 AudioLevel（频谱与电平表）

#### 插件本身
- **Windows：** 通过 WASAPI 环回采集，监测 Windows 音频端点混音后的信号。
- **Mac：** 原生实现（`AudioLevel`、`AudioLevel.dll`、`Plugins\AudioLevel.dll`）。一个共享的采集引擎服务所有皮肤：无论多少
  皮肤使用同一个音频流，都只采集一次；皮肤窗口中第一个父 measure 第一次更新时开始（只是检查皮肤——管理窗口检查未加载的
  皮肤——或用 `--render` 绘制皮肤时从不开始），最后一个消失 3 秒后停止；皮肤更新暂停期间（睡眠、显示器睡眠、其他用户的
  会话）采集也会暂停。在 Apple 芯片上，典型频谱皮肤占用单个核心的 0.1–0.3 %。
- **原因：** macOS 上没有 WASAPI。
- **对皮肤的影响：** 对皮肤作者没有影响。
- **状态：** 模拟实现

#### `Port=Output`（系统音频），macOS 14.2 及以上
- **Windows：** 环回采集默认（或 `ID` 指定的）输出端点。
- **Mac：** 使用 Core Audio 进程 tap：不写 `ID` 时是所有 App 播放内容的立体声混音；`ID` 指定某个输出设备时，采集该设备的
  音频流。输出设备、设备列表或采样率变化时会重新创建（约 0.3 秒的间断）。同时带有输入的输出设备（USB 声卡、耳机）不会加入
  采集用的聚合设备，因此频谱皮肤绝不会录下麦克风，也不会让蓝牙耳机切换到通话模式。
- **原因：** 进程 tap 是采集系统音频的公开 API。
- **对皮肤的影响：** macOS 会询问一次 **系统录音** 权限，频谱皮肤运行期间显示紫色的录音指示点。如果拒绝，macOS 只提供静音
  （电平为 0）。当系统音频流在相隔 10 秒的两次检查中都只有数字静音、而其他 App 正在播放声音时，皮肤会得到一条指向该权限的
  兼容性提示（有声音后提示消失）。
- **状态：** 模拟实现

#### macOS 13 – 14.1 上的 `Port=Output`
- **Windows：** 同上。
- **Mac：** 用 ScreenCaptureKit 采集整个系统的混音；需要 **屏幕录制** 权限，授权后要重启 Deskset；`ID` 不能选择设备。
- **原因：** 14.2 之前没有进程 tap。
- **对皮肤的影响：** 频谱皮肤请求屏幕录制权限会让人意外；授权前数值为 0。
- **状态：** 模拟实现（未在这些 macOS 版本上测试）

#### `Port=Input`
- **Windows：** 采集默认（或 `ID` 指定的）输入端点。
- **Mac：** 直接采集输入设备，并跟随默认输入的变化；需要 **麦克风** 权限。
- **原因：** —
- **对皮肤的影响：** 采集期间显示橙色麦克风指示点；被拒绝时为 0，`DeviceStatus` 为 0，并有一条兼容性提示。Deskset 每 10 秒
  重试一次，因此授予麦克风权限后电平会开始工作（提示也会消失）。
- **状态：** 完全一致（权限界面不同）

#### `ID`
- **Windows：** 形如 `{0.0.0.00000000}.{…}` 的 Windows 端点 ID。
- **Mac：** Core Audio 设备 UID，或者为方便起见直接写设备名称（`ID=MacBook Pro Microphone`）。匹配不到的 ID（所有 Windows
  ID 都是如此）回退到默认设备（记录一次日志）。
- **原因：** Windows 端点 ID 在 Mac 上没有意义。
- **对皮肤的影响：** 附带 Windows ID 的皮肤使用默认设备。`Type=DeviceList` 会列出可用的 ID。
- **状态：** 模拟实现

#### 父 / 子 measure 与取舍判断
- **Windows：** 父 measure 负责采集；子 measure（`Parent=`）读取数值；只有 Type、Channel、FFTIdx 和 BandIdx 可以动态修改。
- **Mac：** 相同（父 measure 的选项只读取一次）。取舍判断：无效的 `Port` 视为 Output；父 measure 自身的值为 0，除非它有
  `Type`；父 measure 缺失或错误、Type 或 Channel 未知的子 measure 读数为 0 / Sum，并给出一条警告；加载时被禁用的父
  measure 在启用前不会开始采集，之后才用 `!DisableMeasure` 禁用的父 measure 会继续采集（录音指示点也保持显示），直到皮肤
  刷新或卸载。
- **原因：** 手册对此没有规定。
- **对皮肤的影响：** 对有效的皮肤没有影响。
- **状态：** 完全一致

#### `Channel`
- **Windows：** L/FL/0、R/FR/1、C/2、LFE/3、BL/4、BR/5、SL/6、SR/7、Sum/Avg。
- **Mac：** 名称相同。默认的系统音频流是立体声混音，因此 C、LFE、BL、BR、SL、SR 在其中为 0；如果 `ID` 指定了多声道设备，
  编号就是该设备音频流中的位置（按设备的顺序，而不是 Windows 的扬声器顺序）。单声道输入的 L、R、C 都返回唯一的声道。
- **原因：** macOS 为全局 tap 把各 App 混成立体声。
- **对皮肤的影响：** 5.1 / 7.1 声道表保持为 0，除非皮肤指定了多声道设备。
- **状态：** 部分支持

#### RMS 与 Peak（`RMSAttack`、`RMSDecay`、`RMSGain`、`PeakAttack`、`PeakDecay`、`PeakGain`）
- **Windows：** 手册写明了意图（平方、平均、开方；attack / decay 插值时间），但没有给出公式。
- **Mac：** 以 5 ms 为一片，驱动一个单极点跟随器，上升时用 attack 时间，下降时用 decay 时间；乘以增益后限制在 0…1。满幅
  正弦波读数为 0.707（RMS）/ 1.0（Peak）。0.1 秒没有音频时数值逐渐衰减而不是冻结；采集停止时归零。
- **原因：** 时间常数跟随器是 attack / decay 时间的标准含义。
- **对皮肤的影响：** 指针的运动速度可能与 Windows 略有不同。
- **状态：** 模拟实现

#### FFT、Bands 与 Sensitivity
- **Windows：** FFTSize、FFTOverlap（Hann 窗）、FFTIdx、Bands（对数间隔）、FreqMin / FreqMax、Sensitivity（dB 范围）、
  FFTAttack / FFTDecay。
- **Mac：** 使用 Hann 窗的 vDSP FFT（支持非 2 的幂的尺寸；FFTSize ≤ 65536；每秒最多计算约 60 次）。每个频带对其对数间隔
  范围内的功率谱做积分并按倍频程归一，因此粉红噪声画出一条平线，电平也不随频带数量变化。数值 =
  `1 + (dB + 10) / Sensitivity`，限制在 0…1（以典型音乐校准的取值）。attack / decay 作用于显示的 0…1 数值。FFTFreq 使用
  音频流的采样率；BandFreq 是频带的几何中心。
- **原因：** 手册没有定义参考电平，也没有说明如何合并频点。
- **对皮肤的影响：** 同样的音乐，柱子高度可能比 Windows 上略高或略低；可调整 `Sensitivity`。频带标签可能相差半个频带。
- **状态：** 模拟实现

#### `Type=Format`、`DeviceStatus`、`DeviceName`、`DeviceID`、`DeviceList`
- **Windows：** 格式文字、状态 0 / 1、名称 / ID、设备 ID 列表。
- **Mac：** Format 形如 `48000 Hz, 32-bit float, 2 channels`；采集期间 DeviceStatus 为 1（无法检测系统录音权限被拒绝，
  因此仍为 1）；Mac 的设备名称和 UID，采集开始前即可读取；DeviceList 每行一个 `UID: 名称`。
- **原因：** 这些格式没有文档。
- **对皮肤的影响：** 措辞不同；解析 Windows 列表格式的皮肤无法匹配。
- **状态：** 模拟实现 / 部分支持（DeviceStatus）

### 10.2 Win7Audio（音量、静音、输出设备）

#### 插件及其数值
- **Windows：** 控制 Windows 默认输出端点；数值 = 音量 0–100；字符串 = 设备名称。
- **Mac：** 默认的 Core Audio 输出设备（`Win7AudioPlugin`、`.dll`、`Plugins\…`、`Win7Audio`）；无需权限。数值 = 取整的音量
  百分比，**静音时为 −1**（皮肤就是这样判断的），没有音量控制的设备（HDMI、部分 USB DAC）为 100；字符串 = Mac 设备名称。
  命令会立即更新显示的数值，并异步发送到设备；快速重复的命令（滚轮）会逐次累加。
- **原因：** 静音时为 −1 虽不在手册中，但皮肤依赖这一点。
- **对皮肤的影响：** 针对真实插件编写的皮肤表现相同。
- **状态：** 模拟实现

#### 命令
- **Windows：** SetVolume、ChangeVolume、ToggleMute、ToggleNext、TogglePrevious、SetOutputIndex。
- **Mac：** 全部支持。结果限制在 0…100；接受公式。没有静音控制的设备通过把音量设为 0 再恢复来实现静音。也接受 `Mute` /
  `Unmute`。切换设备时设置 macOS 的默认输出；`SetOutputIndex` 从 1 开始；超出范围的序号被忽略（记录日志）。未知命令记录
  日志。
- **原因：** 手册既没有给出设备顺序，也没有给出序号的起始值（取舍判断）。
- **对皮肤的影响：** 设备顺序与 Windows 不同；写死序号的皮肤指向的是 Mac 上的设备。
- **状态：** 模拟实现

### 10.3 AppVolume（第三方，按 App 的音频）

#### App 列表、音量、峰值与静音
- **Windows（插件 README）：** 每个 App 的会话都有自己的音量、峰值和静音。
- **Mac：** 列表来自 Core Audio 的音频客户端（macOS 14.2 及以上）：程序坞中的 App，加上 `IgnoreSystemSound=0` 时其他正在
  播放的进程；名称是可执行文件名。**音量** 始终为 1.0（静音时为 0），`SetVolume` 被拒绝——macOS 没有单个 App 的音量。
  **峰值** 来自该 App 的进程 tap（需要系统录音权限；只在皮肤窗口中，因此渲染时为 0）。**静音** 会创建一个静音 tap，使该
  App 静音，直到取消静音或 Deskset 退出。浏览器通过辅助进程播放声音，这些进程只在 `IgnoreSystemSound=0` 时列出。
- **原因：** macOS 有针对单个 App 的 tap，但没有单个 App 的音量。
- **对皮肤的影响：** 单个 App 的音量滑块不起作用；macOS 14.2 之前列表为空。卸载或刷新皮肤不会取消它设置的 App 静音（与
  Windows 相同）；macOS 没有可以取消静音的混音器，所以要等皮肤取消静音或 Deskset 退出后该 App 才会再次发声。
- **状态：** 部分支持

### 10.4 音乐播放器：NowPlaying、iTunes、WebNowPlaying、MediaKey

#### 如何使用自动化权限
- **Windows：** 没有对应的机制。
- **Mac：** 第一次向*正在运行*的播放器发送 Apple Event 之前，Deskset 会检查权限并让 macOS 显示提示；只有明确拒绝才会停止
  轮询该播放器，并且每 30 秒重新检查一次，之后再授权无需重启。轮询从不启动播放器。
- **原因：** macOS 对 Apple Event 的隐私保护。
- **对皮肤的影响：** 出现一次 “Deskset 想要控制 Music / Spotify” 的提示。
- **状态：** 模拟实现

#### NowPlaying：`PlayerName`
- **Windows：** AIMP、CAD（foobar2000、MusicBee……）、iTunes、Winamp、WMP、Spotify、WLM，或 `[MainMeasure]`。
- **Mac：** 只能读取 Music.app 和 Spotify。`Spotify` 优先 Spotify；其他所有名称优先 Music.app。显示 **谁在播放就显示谁**：
  首选播放器在播放时显示它，否则显示另一个正在播放的播放器，否则显示上次显示过且处于暂停的播放器，依此类推。
  `[MainMeasure]` 引用可用（最多 8 层）。没有 Mac 版本的播放器名称（Winamp、foobar2000、AIMP、WMP、MusicBee……）会添加一条
  兼容性提示，说明改为显示哪个播放器。
- **原因：** 这是 macOS 上可以脚本控制的播放器；Windows 皮肤写死的播放器 Mac 用户未必使用。
- **对皮肤的影响：** 为任何播放器编写的皮肤都能配合 Mac 用户正在用的播放器。
- **状态：** 模拟实现

#### NowPlaying：其他播放器（QQ 音乐、网易云音乐、浏览器、VLC……）
- **Windows：** 同样只支持上面列出的播放器。
- **Mac：** 不读取。这些播放器没有脚本接口；而且从 macOS 15.4 起，系统级的「正在播放」信息（控制中心显示的那份）
  只允许苹果签名的进程读取。Deskset 不绕过这道限制（例如借用 `osascript`、`perl` 等苹果签名的程序），因为这等于绕开
  平台的隐私限制，苹果随时可能封堵。
- **原因：** 没有公开 API；私有 API 被系统限制。
- **对皮肤的影响：** 只有这类播放器在播放时，NowPlaying measure 为空，皮肤显示自己的占位图。
- **状态：** 不支持

#### NowPlaying：`PlayerType` 数值
- **Windows：** Artist、Album、Title、Number、Year、Genre、Cover、File、Duration、Lyrics、Position、Progress、Rating、
  Repeat、Shuffle、State、Status、Volume。
- **Mac：** 全部支持。Duration / Position 为 `MM:SS`（超过一小时为 `H:MM:SS`，取舍判断），两次轮询之间做插值；Rating =
  Music 的星级（Spotify 没有：0）；App 运行期间 Status = 1；Genre、Year、Lyrics 仅限 Music；File = 曲目文件路径（流媒体为
  “”）；接受 `CoverPath` 作为同义词；Progress、Volume、Rating、State 和 Position / Duration 自动设定 MaxValue。
- **原因：** macOS 播放器提供的数据。
- **对皮肤的影响：** Music.app 完全相同；Spotify 缺少流派 / 年份 / 歌词 / 评分（Windows 上也是如此）。
- **状态：** 完全一致（Music）/ 部分支持（Spotify）

#### NowPlaying：歌词与封面
- **Windows：** 歌词从歌词网站下载；Cover 是图片文件的路径。
- **Mac：** 歌词取 Music.app 中曲目自带的歌词（不联网查找）。封面（Music 的插图或 Spotify 的封面网址）写入
  `~/Library/Caches/Deskset/NowPlaying/`，每首曲目使用新的文件名；没有封面时为 “”，因此
  `Substitute="":"#@#NoCover.png"` 可用。本地文件的封面取 Music 的插图。从 Apple Music 在线播放的曲目，Music 的插图要晚
  几秒才有、或者根本没有，刚切歌时还经常给出上一首的图，所以切歌后立即用苹果公开的 iTunes Search API 按「歌手 + 歌名」
  在线查询（先查用户所在地区的商店，查不到再查一个：中文歌名查台湾区，其他查美国区；拼音写法的歌手名、繁简体都能对上；
  歌名或专辑也必须对上，绝不会拿同一歌手的另一首歌的封面顶替）。
  Music 的插图作为后备：30 秒内多次询问，它给出的属于其他专辑曲目的图会被丢弃，显示后还会再核对。在线查询会把正在播放的
  歌手和歌名发给苹果——只针对在线曲目和没有插图的文件，且只在有皮肤显示封面时。可用
  `defaults write app.deskset.Deskset OnlineCoverLookup -bool NO` 关闭（每次查询前读取，无需重启）；`NowPlayingDebug`
  会把每一步写进日志。
- **原因：** 不抓取第三方网站；播放器提供的是数据而不是文件；Music 对在线曲目的插图会延迟、缺失或给出旧图。
- **对皮肤的影响：** 没有内嵌歌词的曲目以及 Spotify 的歌词为空；在线曲目的封面在切歌后约 1～3 秒出现。
- **状态：** 部分支持（歌词）/ 完全一致（封面；Apple Music 在线曲目为模拟实现）

#### NowPlaying：轮询、TrackChangeAction、PlayerPath、命令
- **Windows：** 每次更新读取播放器；换曲时执行 TrackChangeAction；PlayerPath 用于启动播放器；Play、Pause、PlayPause、Stop、
  Next、Previous、OpenPlayer、ClosePlayer、TogglePlayer、SetPosition、SetRating、SetShuffle、SetRepeat、SetVolume。
- **Mac：** 一个共享的后台轮询器，每秒一次，只针对正在运行的播放器，而且只在有皮肤需要数据时运行（30 秒无人读取即暂停）；
  数值在加载后的下一次更新出现。TrackChangeAction 在真正换曲时执行（第一首不算，停止也不算）。PlayerPath 只有指向 Mac 的
  `.app` 时才使用。所有命令都可用；Spotify：Stop = 暂停，没有评分；播放命令从不启动已关闭的播放器。
- **原因：** Apple Event 很慢，绝不能阻塞皮肤。
- **对皮肤的影响：** 数据最多延迟一秒（播放位置有插值）。
- **状态：** 模拟实现

#### NowPlaying：两次 measure 更新之间的字符串
- **Windows：** GetString 是按需调用的；NowPlaying 的字符串在 measure 两次更新之间何时刷新，文档没有说明，但歌曲信息皮肤
  依赖这一点（Monstercat Visualizer 每 10～20 秒才读一次歌名，切歌却立刻显示）。
- **Mac：** meter、节变量和 Lua 读到的 NowPlaying、iTunesPlugin、WebNowPlaying 字符串是播放器的当前数据，Substitute
  照常生效；数值、IfCondition、IfMatch、OnChangeAction 和 TrackChangeAction 仍跟随 measure 自己的更新。被禁用或暂停的
  measure 保留 meter 最后看到的字符串。取舍判断：不论 UpdateDivider 是多少，字符串都跟随播放器。
- **原因：** 否则这类皮肤切歌后要晚 10～20 秒才显示新歌。
- **对皮肤的影响：** 切歌后约一秒内，歌名、歌手和封面就会跟着变；即使 measure 几秒才更新一次，播放位置这类字符串也每秒变化。
- **状态：** 模拟实现

#### iTunes 插件（已弃用的 `iTunesPlugin`）
- **Windows：** 针对 iTunes 的 `Command=Get…` 数值和 bang 命令；DefaultArtwork。
- **Mac：** 相同的数值和命令，来自 Music.app（或按“谁在播放就显示谁”规则来自 Spotify）；Bitrate、BPM、SampleRate、Size、
  Comment、Composer、EQ 仅来自 Music；Power = 打开 / 退出；ToggleiTunes 隐藏或显示 Music；`Command=<bang>` 的 measure 在
  `!CommandMeasure M ""` 和旧的 `!PluginBang` 时执行它的 bang；DefaultArtwork 是曲目没有封面时返回的占位图（取舍判断）。
- **原因：** iTunes 已变为 Music.app。
- **对皮肤的影响：** 老的 iTunes 皮肤（PogPack 的音乐标签页）可以配合 Music.app 使用。
- **状态：** 完全一致

#### WebNowPlaying（第三方）
- **Windows：** 浏览器扩展把网页播放器（YouTube、SoundCloud、网页版 Spotify……）的媒体信息发送给插件。
- **Mac：** 不支持浏览器扩展（会有兼容性提示说明）；measure 改为显示 Music.app / Spotify。所有 PlayerType 和 bang 都可用（Player = “Music” /
  “Spotify”；Repeat bang 按 关 → 全部 → 单曲 循环；点赞 / 点踩分别设为 5 / 1 星）。
- **原因：** 扩展的协议没有公开文档；不使用私有 API 就无法读取网页媒体。
- **对皮肤的影响：** WebNowPlaying 皮肤可以作为 Music / Spotify 小组件使用，但不能显示浏览器中的媒体。
- **状态：** 部分支持

#### MediaKey
- **Windows：** 发送多媒体键：NextTrack、PrevTrack、Stop、PlayPause、VolumeMute、VolumeDown、VolumeUp。
- **Mac：** 有辅助功能权限时（Deskset 从不主动请求），发送真实的媒体键事件，任何正在播放的 App 都能收到，并显示音量 HUD。
  没有该权限时（默认情况），切歌键通过自动化发给 Music / Spotify，音量键直接修改默认输出设备的音量（每按一次 ±2 %，静音
  切换，调高音量会取消静音；不显示 HUD）。Stop 始终发给播放器（Mac 键盘没有 Stop 键）。另外接受：`Next`、`Prev`、
  `Previous`、`PreviousTrack`、`Play`、`Pause`、`Mute`。
- **原因：** 在 macOS 上发送键盘事件需要辅助功能权限。
- **对皮肤的影响：** 没有辅助功能权限时，切歌键只能控制 Music / Spotify（不能控制浏览器）。
- **状态：** 模拟实现

### 10.5 WiFiStatus

#### SSID 与 LIST（定位服务）
- **Windows：** 当前连接的 SSID；可见网络列表 LIST（样式 0–7、数量上限）。
- **Mac：** 使用 CoreWLAN。macOS 只把网络名称提供给拥有 **定位服务** 权限的 App，第一次加载 SSID / LIST measure 时会请求；
  没有权限时 SSID 和 LIST 为空。没有“正在连接…”状态。列表来自系统最近一次扫描（Deskset 只在首次强制主动扫描一次，之后最多
  每 5 分钟一次——扫描会干扰通话和游戏）；每个 SSID 一行，信号最强的在前；质量写作 `[80%]`。
- **原因：** macOS 的隐私保护；扫描既慢又会造成干扰。
- **对皮肤的影响：** 出现定位服务提示；列表可能比实际情况滞后几分钟。
- **状态：** 模拟实现

#### Quality、TXRate、RXRate、Encryption、AUTH、PHY、WiFiIntfID
- **Windows：** 信号质量百分比、发送 / 接收速率、加密方式、认证方式、PHY 类型、接口序号。
- **Mac：** Quality = 2 × (RSSI + 100)，限制在 0–100（取舍判断）；TXRate = 链路速率；**RXRate = TXRate**（macOS 只报告一个
  速率）；Encryption / AUTH 由 macOS 的组合安全模式映射而来（少见的 Windows 数值不会出现）；PHY 为 802.11a/b/g/n/ac/ax/be；
  数值在主线程之外刷新，最多每 2 秒一次，加载后的下一次 measure 更新才出现。
- **原因：** CoreWLAN 只提供 RSSI、一个速率和组合的安全模式。
- **对皮肤的影响：** RXRate 等于 TXRate；UpdateDivider 较大的 measure 在第二次更新前显示 0。
- **状态：** 模拟实现（RXRate 部分支持）

### 10.6 InputText

#### 输入框
- **Windows：** 位于 measure 的 X / Y / W / H 处的浮动编辑框；与 Stay Topmost 皮肤不兼容。
- **Mac：** 放在皮肤上方的无边框非激活面板中的原生文本框：你原来使用的 App 保持在最前面，输入结束后键盘交还给它。皮肤移动
  时输入框跟随。取舍判断：未设置 TopMost = 紧贴在皮肤之上；缺少 W = 皮肤剩余的宽度；缺少 H = 字体行高 + 6。
- **原因：** 皮肤窗口无法承载文本框。
- **对皮肤的影响：** 与 Windows 不同，在 Stay Topmost 皮肤上也能用。
- **状态：** 模拟实现

#### 选项、按键、命令
- **Windows：** SolidColor、FontColor、FontFace、FontSize、StringStyle、StringAlign、DefaultValue、Password、InputLimit、
  InputNumber、TopMost、FocusDismiss、OnDismissAction；Enter 提交，Escape 取消，Ctrl+Enter 换行；`$UserInput$`、
  `ExecuteBatch`。
- **Mac：** 支持所有选项（在 bang 执行时读取；字体与 String meter 的解析方式相同）。Ctrl+Enter 或 Option+Enter 插入换行（一个
  字符）。FocusDismiss=1：点按其他地方或 ⌘Tab 即取消；FocusDismiss=0：Deskset 自己窗口中的点按会被拦截，但 macOS 上无法拦截
  其他 App 中的点按。批处理会先收集所有输入，再执行所有命令；Escape 取消整个批处理并执行 OnDismissAction。
- **原因：** macOS 不能全局禁用鼠标。
- **对皮肤的影响：** 很小。
- **状态：** 模拟实现

### 10.7 窗口、桌面与颜色插件（第三方）

#### FrostedGlass
- **Windows：** 整个皮肤窗口背后的 DWM 效果：Blur、Acrylic、Mica、MicaAcrylic、MicaAlt、Backdrop……；Windows 11 上的圆角
  和边框。
- **Mac：** 在皮肤后面的子窗口中使用 macOS 的毛玻璃效果（NSVisualEffectView），跟随皮肤的位置、层级和透明度。Blur → HUD
  材质，Acrylic → 弹出框材质 + 着色，Mica → 窗口下方背景，MicaAcrylic → 侧边栏 + 着色，MicaAlt → 窗口背景；Backdrop 类型 =
  纯色。8 / 8 / 4 点的圆角也会裁剪皮肤；方角边框没有阴影；DarkMode 强制深色外观；MicaOnFocus 在皮肤不是主窗口时显示平面
  材质；`Effect=` 被忽略；“降低透明度”会把模糊变为纯色。所有命令都可用。`!DisableMeasure` 会保留效果直到刷新（请用
  `DisableBlur`）。
- **原因：** macOS 没有 DWM 效果；材质是原生的对应物。
- **对皮肤的影响：** 外观接近但不完全相同；在 `--render` 生成的图片中看不到模糊；淡入淡出时模糊层会分段变化。
- **状态：** 模拟实现

#### Chameleon
- **Windows：** 从壁纸（`Type=Desktop`）或图片（`Type=File`）中取色：Background1/2、Foreground1/2、Light1–4、Dark1–4、
  Average、Luminance。
- **Mac：** 使用皮肤所在屏幕的壁纸（轮换壁纸的文件夹 → 其中第一张图片）或指定文件，在其变化时于后台取样。颜色来自 Deskset 自己
  的聚类方法（原插件的算法没有公开）。ContextAwareColors 和 ForceIcon 被忽略；不是图片文件的动态 / 航拍壁纸使用后备颜色。
- **原因：** 无法得知原插件的方法。
- **对皮肤的影响：** 颜色思路相似，但不完全相同。
- **状态：** 模拟实现

#### IsFullScreen
- **Windows：** 焦点窗口全屏时为 1；字符串 = 其进程名（`chrome.exe`）。
- **Mac：** 最前面 App 的窗口覆盖主显示器时为 1（原生全屏和无边框游戏；“缩放”的窗口不算全屏）；字符串 = App 的可执行文件名
  （`Safari`）。无需权限。
- **原因：** macOS 上 App 的命名方式不同。
- **对皮肤的影响：** `IfMatch=chrome.exe` 这类判断永远不会匹配；全屏检测可用。
- **状态：** 部分支持

#### GetActiveTitle
- **Windows：** 焦点窗口的标题。
- **Mac：** 有辅助功能权限时取窗口标题（或有屏幕录制权限时取窗口名）——Deskset 都不会主动请求；否则取最前面 App 的名称。
- **原因：** 在 macOS 上窗口标题属于隐私数据。
- **对皮肤的影响：** 除非用户授予权限，否则显示 App 名称。
- **状态：** 部分支持

#### SysColor
- **Windows：** Windows 系统颜色（强调色、窗口、高亮、按钮表面……）。
- **Mac：** 映射到当前浅色 / 深色外观下的 macOS 语义颜色（强调色 → 强调色，高亮 → 选中内容背景，窗口 → 窗口背景，文字 → 标签
  颜色……）；开启“降低透明度”时 `DWM_OPAQUE_BLEND` = 1。
- **原因：** Windows 的颜色槽位在 macOS 上不存在。
- **对皮肤的影响：** 使用强调色的皮肤会跟随 Mac 的强调色。
- **状态：** 模拟实现

---

## 11. WebParser 与皮肤安装器

### 11.1 WebParser

WebParser 遵循手册；正则表达式是转换为 ICU 的 PCRE（见[动作、bang、Substitute 与正则表达式](#动作bangsubstitute-与正则表达式)）。
以下说明来自 WebParser 实现及其审查时的记录，并已对照当前代码核实。

#### 父子 measure 的数值（取舍判断）
- **Windows：** 手册没有说明 `StringIndex=0`、空 RegExp 或子 measure 匹配失败时的结果，也没有说明字符串如何变成数字。
- **Mac：** StringIndex 0（默认）是整个匹配；没有 RegExp 时整段文字就是值；数值取字符串开头的数字（“23.5°C” → 23.5）。
  RegExp 匹配失败的子 measure 保留旧值，与父 measure 一样；StringIndex 指向不存在的捕获组时，该子 measure 及其下级全部为空
  （即前瞻技巧中的“空值”）。整棵树的数值都在任何动作执行之前设置好。
- **原因：** 手册没有规定。
- **对皮肤的影响：** 对在 Windows 上正常的皮肤没有影响。
- **状态：** 完全一致（取舍判断）

#### 被禁用或暂停的子 measure（取舍判断）
- **Windows：** “子 WebParser measure 的值是父 measure 的函数，只在父 measure 更新时才更新”；手册没有说明此时被禁用或暂停的
  子 measure 会得到什么。有些皮肤在父 measure 的 FinishAction 中启用子 measure（Monstercat Visualizer 的更新检查就是这样），
  并期望它显示父 measure 刚读到的内容。
- **Mac：** 这样的子 measure 在父 measure 读取资源时照样得到数值（`Download=1` 的子 measure 照样下载），并在重新运行后的第一次
  更新时显示出来。加载皮肤时处于禁用或暂停状态的 WebParser measure 仍会读取一次自己的选项，好让父 measure 知道它；禁用期间
  更改的选项在它重新运行时读取，从父 measure 的下一次读取起生效，与对子 measure 使用 `!SetOption` 相同。
- **原因：** 手册没有规定；这类皮肤需要这样。
- **对皮肤的影响：** 对在 Windows 上正常的皮肤没有影响。
- **状态：** 完全一致（取舍判断）

#### 动作与错误
- **Windows：** FinishAction、OnRegExpErrorAction、OnConnectErrorAction、OnDownloadErrorAction。
- **Mac：** 每个带 RegExp 或 `Download=1` 的 measure 执行自己的动作；普通子 measure 不执行。连接失败时执行
  OnConnectErrorAction；获取网页时，只要有 HTTP 响应就算连接成功（404 页面也会被解析，RegExp 通常匹配失败 →
  OnRegExpErrorAction）；下载时 HTTP 错误执行 OnDownloadErrorAction。
- **原因：** 依据手册对 OnRegExpErrorAction 的描述。
- **对皮肤的影响：** 预计无。
- **状态：** 完全一致

#### 网络行为
- **Windows：** 默认 User-Agent 为 “Rainmeter WebParser plugin”；有 IgnoreCertName / IgnoreCertDate 之类的选项；
  Rainmeter.data 中可以有全局 `[WebParser]` 节。
- **Mac：** 默认 User-Agent 为 “Deskset WebParser”（皮肤可以自己设置 `UserAgent`）。IgnoreCertName 和 IgnoreCertDate 被拒绝
  ——证书检查始终开启——并作为兼容性提示列出。HTTP → HTTPS 的重定向总是跟随，HTTPS → HTTP 只有设置 IgnoreHTTPRedirect 时才
  跟随；ProxyServer 不写端口时使用 80；不支持全局 `[WebParser]` 节。普通 `http://` 网址可用。网址的编码比手册列出的更彻底
  （避免被 macOS 重复编码）。
- **原因：** 产品不能自称为 Rainmeter；证书检查保护用户。
- **对皮肤的影响：** 依赖无效证书的皮肤无法获取那些网页。
- **状态：** 模拟实现 / 部分支持（证书相关选项）

#### 文字解码
- **Windows：** `CodePage`、`DecodeCharacterReference`、`DecodeCodePoints`。
- **Mac：** CodePage=0 时依次检测字节顺序标记、有效的 UTF-8、HTTP 声明的字符集，最后回退到 ANSI；字符引用使用 HTML 4 的
  名称加上 `&apos;`（数字引用 128–159 按 Windows-1252 解释）。
- **原因：** 对真实网页的宽松处理。
- **对皮肤的影响：** 预计无。
- **状态：** 完全一致

#### 本地文件、`Debug2File`、`UpdateRate`
- **Windows：** `file://` 可以读取任意路径；Debug2File 写出调试文件；UpdateRate 表示两次获取之间的更新次数。
- **Mac：** 在 App 中，`file://` 只能读取皮肤文件夹和 Deskset 设置文件夹（`#SETTINGSPATH#`）中的文件（按跟随链接后的实际
  路径判断）；其他路径按文件不存在处理（记录日志）。Debug2File 必须位于皮肤文件夹内（否则写到皮肤文件夹中的
  `WebParserDump.txt`），以 UTF-8 写入。UpdateRate ≤ 0 时只获取一次，之后只在 `!CommandMeasure … Update` 时获取。
- **原因：** 读取私人文件的皮肤可能通过另一个 WebParser 的网址把内容发出去。
- **对皮肤的影响：** 解析皮肤文件夹以外文件的皮肤得不到内容。
- **状态：** 部分支持

### 11.2 皮肤安装器

Deskset 能安装的包比 Rainmeter 更多，因此老皮肤也能一步安装。详细说明：[`compat/installer.md`](compat/installer.md)。

| 输入 | Rainmeter（Windows） | Deskset（Mac） |
| --- | --- | --- |
| Skin Packager 制作的 `.rmskin`（ZIP + 结尾标记 + `RMSKIN.ini`） | 安装 | 安装 |
| 有结尾标记但没有 `RMSKIN.ini` 的 `.rmskin` | 拒绝 | 拒绝（除非包含 `Rainstaller.cfg`） |
| 旧版 Rainstaller 的 `.rmskin`（没有结尾标记，含 `Rainstaller.cfg`） | 自 2.3 / 2.4 起拒绝 | 安装 |
| 改名为 `.rmskin` 的普通 ZIP 或 `.zip`，含 `RMSKIN.ini` | 自 2.3 起拒绝 | 安装 |
| 没有清单文件的普通 ZIP | 手动安装 | 安装（自动识别根配置） |
| 已解压的文件夹 | 手动安装 | 安装（复制，从不移动） |
| 内含一个 `.rmskin` 的下载 ZIP | 先解压，再安装 | 一步安装 |
| 内含多个 `.rmskin` 的 ZIP | 解压后逐个安装 | 拒绝，并列出这些包 |
| `.rar`、`.7z` | 手动安装 | 不支持——请先解压，再安装文件夹 |

#### 在 App 中打开皮肤包
- **Windows：** 双击 `.rmskin` 会运行皮肤安装器；其他格式需要手动安装。
- **Mac：** 可以双击 `.rmskin` 文件、ZIP 压缩包和文件夹（仅 `.rmskin` 默认用 Deskset 打开），用“打开方式 → Deskset”打开，拖到
  App 图标或管理窗口上，或用“安装皮肤…”选择。Deskset 从不成为 ZIP 压缩包或文件夹的默认打开程序。多个项目会依次安装。本身就是、
  包含或位于皮肤文件夹中的文件夹会在复制之前被拒绝（手动放进去的皮肤在“全部刷新”后出现）。
- **原因：** 大多数下载网站提供的是 ZIP 或文件夹。
- **对皮肤的影响：** 在 Windows 上需要“解压到 Documents\Rainmeter\Skins”的皮肤可以一键安装。
- **状态：** 模拟实现

#### 确认对话框与安装之后
- **Windows：** 皮肤安装器显示头图、名称、作者、版本、皮肤、布局和插件；旧版本被备份并替换，然后加载包指定的皮肤或布局。
- **Mac：** 提示框显示头图、“安装“名称”？”、作者和版本；普通压缩包或文件夹会注明皮肤是自动识别的（文件夹会被复制，原件保留），
  旧版包会注明这一点；列出根配置以及它们是替换（会备份）还是添加到已安装的配置；布局（会保存，但不应用）；安装会添加的字体
  （“不做系统级安装”）；安装后会加载什么；Windows 插件（从不安装）及其他警告。被替换的根配置中正在运行的皮肤会先停止，安装后
  重新加载；包指定的皮肤会淡入加载，并在管理窗口中选中。
- **原因：** —
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 包格式（普通 ZIP、结尾标记、外层文件夹）
- **Windows：** “从 2.3 版起，Rainmeter 不会安装改为 .rmskin 扩展名的普通 ZIP 文件”；打包器把 `RMSKIN.ini` 放在最顶层。
- **Mac：** 没有结尾标记的文件只要是 ZIP 就接受（含 RMSKIN.ini、含 Rainstaller.cfg 或两者都没有）；*带有*结尾标记的文件必须
  包含清单文件（缺少清单意味着包已损坏）。清单会在顶层以及最多三层“唯一的外层文件夹”中查找（旁边零散的说明或预览文件不影响）。
  ZIP 与结尾标记之间的字节被忽略。
- **原因：** 皮肤网站上的很多包是手工压缩的，或是为旧版 Rainstaller 制作的（取舍判断）。
- **对皮肤的影响：** Rainmeter 4 拒绝的包在 Mac 上可以安装。
- **状态：** 模拟实现

#### 解压安全
- **Windows：** 没有写明。
- **Mac：** 写入任何东西之前先检查 ZIP 目录：拒绝绝对路径、盘符、`..`、NUL 字节和符号链接，也拒绝超过 200 000 个条目或 4 GB
  的压缩包；解压过程受监控以防 ZIP 炸弹（300 秒超时）。删除链接、特殊文件和 `__MACOSX`；带 `\` 的名称变为文件夹；非 UTF-8
  的名称按代码页 437 读取；下载文件的隔离标记会传递下去，因此 Gatekeeper 会继续检查皮肤启动的任何东西。ZIP 中如果没有列出任何
  `.ini`（也没有 `Rainstaller.cfg` 或内含的 `.rmskin`），在解压前就会被拒绝。
- **原因：** macOS 的安全要求；皮肤从来不需要链接。
- **对皮肤的影响：** 含有符号链接（即使是无害的）的包会被拒绝。在某些语言设置的 Mac 上，非常老的包的文件夹名可能出现奇怪字符。
- **状态：** 模拟实现

#### 隐藏文件
- **Windows：** “Skin Packager 会忽略任何隐藏的文件或文件夹”。
- **Mac：** 以 `.` 开头的名称、`__MACOSX`，以及 Windows 的隐藏文件 `desktop.ini`、`Thumbs.db`、`ehthumbs.db` 从不安装；备份
  会保留所有内容。
- **原因：** 规则相同；在 macOS 和 Windows 上制作的 ZIP 都会带有这类杂项。
- **对皮肤的影响：** 无。
- **状态：** 完全一致

#### RMSKIN.ini 与头图
- **Windows：** 手册记录了打包器的字段但没有写键名；头图必须是 400×60 的 `.bmp`；不满足最低 Rainmeter / Windows 版本的包会被
  安装器拒绝。
- **Mac：** `[rmskin]` 的键为 Name、Author、Version、LoadType、Load、VariableFiles、MergeSkins（也接受 `Merge`）、
  MinimumRainmeter、MinimumWindows（UTF-8 / UTF-16 / ANSI）。**不检查最低版本。** `RMSKIN.bmp` 只要是真正的位图且不超过
  4096 像素就会显示（不要求精确尺寸）。
- **原因：** Windows 版本号在 macOS 上没有意义；不支持的功能由引擎报告。
- **对皮肤的影响：** 为更新版本的 Rainmeter 制作的包也能安装；不支持的功能会优雅降级。
- **状态：** 完全一致 / 不支持（最低版本）

#### 根配置、备份与合并皮肤
- **Windows：** 每个包一个根配置；已存在的皮肤会“移到备份文件夹”；合并皮肤时“根配置文件夹不会被删除或备份”。
- **Mac：** `Skins/` 中的每个文件夹（`@Vault` 除外）都作为根配置安装。已存在的根配置被移到 `Backups/<根配置>`（之后是
  `(2)`、`(3)`……，旧备份都会保留）；新文件夹先准备好再替换，替换失败时恢复旧文件夹。设置 `MergeSkins=1` 时，把包的内容复制
  到已有文件夹上且不删除任何东西，同时在 Backups 中保留旧文件夹的完整副本（取舍判断）。
- **原因：** 手工制作和旧版的包经常包含多个根配置；备份让用户可以撤销附加组件。
- **对皮肤的影响：** 分成多个根配置的套件能完整安装；Backups 中多一个文件夹。
- **状态：** 模拟实现

#### 变量文件
- **Windows：** 保留已有的变量值；合并皮肤优先；不备份时跳过此选项。
- **Mac：** 对于新旧版本中都存在的每个列出的文件，新旧都有的 `[Variables]` 键都保留用户写下的原值；包中的文件保留其布局、注释、
  新增的键和编码；`@Include…` 行始终来自新版本。即使设置了 MergeSkins 或不备份，也会保留变量值（Rainmeter 在这两种情况下会
  跳过）。
- **原因：** 保留用户的设置总不会更糟。
- **对皮肤的影响：** 无。
- **状态：** 模拟实现

#### 插件、附加程序与 `@Vault`
- **Windows：** 插件 DLL 安装到 Plugins 文件夹并归档到 `@Vault`；旧版的 `Addons\` 程序会被安装。
- **Mac：** DLL 从不安装也不归档；确认对话框会列出它们，并提醒使用这些插件的皮肤不会显示相应数据。附加程序从不安装（会说明）。
  包中的 `@Vault` 合并到 `Skins/@Vault`，不替换已有文件。
- **原因：** Windows 的 DLL 和程序无法在 macOS 上运行。
- **对皮肤的影响：** 依赖不受支持插件的部分保持空白；启动附加工具的按钮不起作用。
- **状态：** 不支持（插件、附加程序）/ 部分支持（`@Vault`）

#### 布局与安装后加载
- **Windows：** 布局安装到 Layouts 文件夹并可以应用；作者可以指定安装后加载的皮肤或布局。
- **Mac：** 布局会被安装（去掉 `[Rainmeter]` 选项），但**暂时不能应用**（App 会说明）。`LoadType=Skin` +
  `Load=Config\File.ini` 在该皮肤是从这个包安装的情况下会被加载。
- **原因：** App 尚未实现布局。
- **对皮肤的影响：** 依靠布局排列的套件可以安装，但需要用户手动加载各个皮肤。
- **状态：** 部分支持

#### 字体
- **Windows：** 旧版包的 `Fonts\` 文件夹曾安装到 `Windows\Fonts`（2.4 起不再如此）；只有 `@Resources\Fonts` 会自动加载；放在
  皮肤旁边的字体需要用户自行安装。
- **Mac：** 包中 `Fonts/` 文件夹里的、包顶层零散的、根配置自己的 `Fonts/` 文件夹里的，以及紧挨着其 `.ini` 文件的
  TrueType / OpenType 字体，都会复制到该根配置的 `@Resources/Fonts`（从不替换已有字体）。不做系统级安装。Windows 位图字体
  （`.fon`、`.fnt`）和 Type 1 字体不安装。
- **原因：** 自动完成 Windows 用户需要手动做的那一步；系统级安装会改变所有 App 的字体列表（取舍判断）。
- **对皮肤的影响：** eClock、HDD Usage Bars、Elegant Watch、Mnml Drives 和 PogPack 无需手动操作即可显示预期的字体。这些字体
  不会提供给其他 Mac App。
- **状态：** 模拟实现

#### 旧版 Rainstaller 包
- **Windows：** 由 Rainstaller（Rainmeter 1.x–2.3）使用；当前的 Rainmeter 会拒绝它们。
- **Mac：** 按 RMSKIN.ini 的方式读取 `Rainstaller.cfg`：Name、Author、Version、`MinRainmeterVer`（不检查）、`Merge=1`、
  `KeepVar`（在每个 `.ini` / `.inc` 中或列出的一组文件中保留用户的变量）、`LaunchType` / `LaunchCommand`（Theme / Layout →
  加载布局；Load / Skin / Config 或 `!ActivateConfig` 之类的 bang → 加载皮肤；从不运行程序）。`Themes\<名称>\Rainmeter.thm`
  变为布局。`AdminRights` 和 `RainmeterFonts` 被忽略。
- **原因：** 这些键没有文档；映射依据键名和真实的包（取舍判断）。
- **对皮肤的影响：** 旧版包连同名称、版本、合并和加载设置一起安装。
- **状态：** 模拟实现

#### 普通压缩包和文件夹（没有清单文件）
- **Windows：** 手动安装：解压，找到皮肤文件夹（可能在 `Skins` 文件夹里），移到 Skins，刷新。
- **Mac：** 同样的步骤，自动完成：含有 `Skins` 文件夹（在顶层或最多三层外层文件夹之下）的压缩包按皮肤包处理；顶层有 `.ini`
  文件或 `@Resources` 的压缩包是一个以压缩包命名的根配置；否则每个含皮肤的顶层文件夹是一个根配置（只有当其下某个文件夹含有
  `@Resources`，或者就是皮肤中 `#SKINSPATH#Name\` 路径所指的文件夹时，单个文件夹才被当作外层文件夹）。根配置以外的说明文件和
  预览图不安装。恰好只有一个皮肤时，安装后会加载它。文件夹会被复制，从不移动；位于皮肤文件夹内的文件夹会被拒绝。从普通压缩包
  重新安装时，与没有变量文件的 `.rmskin` 一样替换根配置：旧版本（包括用户在其文件中改过的设置）进入 Backups。
- **原因：** 取舍判断；手册只说文件夹可能是嵌套的。
- **对皮肤的影响：** 大多数“解压到 Skins”的压缩包都能正确安装。已知的误判（皮肤仍能运行，只是配置名不同）：没有 `@Resources`
  或 `#SKINSPATH#` 线索的外层文件夹会作为多出来的一层保留；没有 `@Resources` 的根配置*内容*直接打包时会拆成多个根配置；布局
  文件夹的 ZIP 会作为根配置安装。
- **状态：** 模拟实现

#### 中断的安装
- **Windows：** 没有写明。
- **Mac：** 如果安装过程中 App 被强制结束，皮肤文件夹中可能残留隐藏的 `.deskset-install-*` / `.deskset-old-*` 文件夹；它们不会
  被自动删除，因为 `.deskset-old-*` 中可能是某个皮肤唯一的副本。
- **原因：** 安全优先于整洁。
- **对皮肤的影响：** 无（不会扫描隐藏文件夹）。
- **状态：** 模拟实现

---

## 12. 真实皮肤测试结果

2026-09-24，用当前版本对 15 个流行的第三方皮肤包（390 个皮肤文件）做了无界面渲染，并与第一轮测试（当时还没有 Lua、内置
插件和最新的引擎修复）进行对比。这些皮肤只在本地测试，Deskset 不分发其中任何一个。原始数据：
[`compat/retest-2026-09-24.md`](compat/retest-2026-09-24.md)。

**方法。** 每个皮肤加载后，间隔 300 ms 更新 3 次，再绘制为 PNG（`Deskset --render`），每次并行 10 个，每个限时 30 秒——一次
按原样，一次使用生成的演示音频和演示的“正在播放”曲目（这样频谱和播放器皮肤无需权限提示也能显示内容）。另外还用安装器把全部
15 个原始下载包安装到临时的 Skins 文件夹，并从那里渲染。主测试使用的是 2026-09-24 合并 App 与引擎接线之前的版本；合并两者之后
的第二轮测试结果相同（见表格最后一行）。

### 12.1 数据

| | 第一轮 | 现在 |
| --- | --- | --- |
| 渲染的皮肤文件 | 390 | 390 |
| 崩溃 / 超时 | 0 / 0 | 0 / 0（使用演示音频时也是 0 / 0，安装后的 390 个副本也是 0 / 0） |
| 兼容性提示（行数） | 614 | 9 |
| 至少有一条提示的皮肤 | 339 | 6 |
| 皮肤日志中的错误行 | 20 | 6（皮肤自身错误、已停止的网络服务，以及未安装、直接从解压文件夹渲染的 PogPack） |
| 安装器能接受的包 | 15 个中 13 个 | 15 个中 15 个 |
| 合并 App 与引擎接线之后 | — | 390 个中 390 个渲染成功，0 崩溃 / 超时（使用演示音频时也是）；8 个皮肤共 11 条提示：上述 9 条，加上 2 条新的“皮肤使用的 Winamp 播放器没有 Mac 版本”提示；不再出现误报的 MeterStyle 警告 |

按原因划分的兼容性提示：

| 提示 | 第一轮 | 现在 |
| --- | --- | --- |
| 不支持 Lua 脚本（`Measure=Script`） | 286 | 0 |
| MeterStyle 不存在（皮肤自身错误，现在只记录日志） | 182 | 0 |
| 不支持 InputText | 41 | 0 |
| CoreTemp 仅限 Windows | 20 | 0 |
| FrostedGlass 仅限 Windows | 17 | 0 |
| WiFiStatus 仅限 Windows | 12 | 0 |
| 不支持 NowPlaying | 11 | 0 |
| Win7AudioPlugin 仅限 Windows | 8 | 0 |
| RecycleManager 仅限 Windows | 7 | 0 |
| Registry 仅限 Windows / 值不可用 | 6 | 2（两个显存值） |
| 不支持 PingPlugin | 5 | 0 |
| PerfMon 仅限 Windows / 计数器不可用 | 3 | 1（`Current Bandwidth`） |
| PowershellRM（第三方 Windows 插件） | 3 | 3 |
| ActiveNet（第三方 Windows 插件） | 2 | 2 |
| AudioLevel、iTunes、ActionTimer、AdvancedCPU、QuotePlugin、RunCommand、UsageMonitor、SysInfo `DOMAINWORKGROUP` | 10 | 0 |
| MSI Afterburner（第三方 Windows 插件） | 1 | 1 |

### 12.2 逐个皮肤包

| 皮肤包（皮肤数） | 现在的结果 | 仍有的差异及原因 |
| --- | --- | --- |
| **CoreLoads**（1） | 各核心负载和图表可用（以前为空） | 温度为 0（没有传感器 API）。下半部分空白是皮肤本身的设计（作者注释掉了第 3–6 核）。 |
| **Elegant Watch**（1） | 时间正确（以前指针停在 12 点）；其字体随包一起安装 | 无 |
| **EasyInfo**（1） | 完整布局和配色（以前是灰色且颜色错误）：LED 时钟、CPU 条形图和曲线、内存、磁盘 | CPU 频率显示 0.000 GHz（Apple 芯片没有公开的频率 API）；核心温度为 0（没有传感器 API）；包中没有其使用的 “Digital-7 Mono” 字体，所以 LED 数字使用后备字体（没有安装该字体的 Windows 上也一样）。 |
| **Enigma**（308） | 由 Lua 驱动的部分现在可用：月历和周历、便笺、订阅阅读器的状态、任务栏宽度和对齐、时钟、音量、正在播放、废纸篓数量、Wi-Fi 质量、占用最高的进程、图片相册（来自 `~/Pictures`） | 天气、位置、日出 / 日落和世界城市数据保持为空，因为皮肤使用的雅虎天气服务已不存在（Windows 上也一样）。订阅阅读器需要用户填写自己的订阅地址。启动器指向 Windows 程序。外网 IP 在网络请求返回后（约 2 秒）才出现。 |
| **FluentDash11**（17） | CPU 和 GPU 名称（“Apple M4 Pro”）、不再塌陷的行、设置按钮、网络、内存、磁盘、系统信息；毛玻璃 | CPU 速度 0.0 GHz、温度 0 °C（没有公开 API）；GPU 频率、显存和风扇为空（MSI Afterburner 插件）；GPU 使用率 0 %；2 网卡和 3 网卡网络皮肤的网卡行重叠（它们依赖 PowershellRM 插件，并且皮肤把文字设置到一个不存在的 meter 名称上）；D:、E:、F: 重复显示启动磁盘。 |
| **HDD Usage Bars**（4） | 三硬盘版本现在在正确位置显示三个硬盘；通过安装器安装后其像素字体也会装好，效果与作者截图一致 | 所有盘符都显示启动磁盘。 |
| **HMNmeter2 / Network Meter**（3） | 实时速率、峰值和总量（以前为空）、ping、外网 IP（约 2 秒后） | ActiveNet（Windows 插件）→ MAC 地址和网卡详情一直显示 “Asking Hardware”；`Current Bandwidth` 为 0；IP 定位服务不返回数据；皮肤中的 Windows 网卡名回退到当前活动接口。 |
| **Mini Weather**（1） | 没有变化 | 没有天气：它使用的 weather.com XML 服务已关闭（Windows 上也一样）。 |
| **Mnml Drives**（2） | 可用；旧版 Rainstaller 包现在可以安装，并带上其像素字体 | 盘符显示启动磁盘。 |
| **Nelamint**（13） | 播放器（曲目、封面）、频谱、CPU、内存、磁盘、时钟、链接、设置 | 天气为空（weather.com XML 服务已关闭）；因为 `UpdateDivider=4`，Wi-Fi 在 3 次更新的测试中为 0（在 App 中会正常显示）。 |
| **PogPack 1.3**（26） | 旧版包现在作为根配置 `PogPack` 安装，带上三个字体，主题变为布局；安装后每个标签页都显示其图形、字体和数值（系统、电池、垃圾箱、信号、音量、音乐控制） | 布局暂时不能应用；Windows 附加程序（配置工具）不会安装；天气为空（weather.com XML 服务已关闭）；音乐的分钟数不显示，因为皮肤的公式引用的是 meter 而不是 measure（皮肤错误，Windows 上也一样）；音乐标签页只在 Music 或 Spotify 运行时显示数据。 |
| **Simple Clean**（8） | 问候语带用户名（以前显示原始的节变量）、播放器和频谱、时钟、设置 | 天气为空（weather.com XML 服务已关闭）；启动 Windows 程序的菜单项不起作用。 |
| **Simplistic Analog Clock**（2） | 时间正确（以前指针错误） | 无 |
| **cpu meter**（1） | 使用其自带的手写体字体正常运行 | 加载后 CPU 数值多一位数字时文字会被截断：皮肤既没有 `W` 也没有 `DynamicWindowSize`（与 Rainmeter 的规则相同）。 |
| **eClock**（2） | 长阴影绘制正确（以前是散开的）；用新安装器安装后，其字体被复制到 `@Resources`，渲染结果与作者的预览图一致 | 直接从解压的文件夹渲染时使用后备字体，因为其字体文件放在皮肤旁边（Windows 用户需要手动安装）。 |

### 12.3 剩余差异的来源

| 原因 | 例子 |
| --- | --- |
| Windows 专属的插件 DLL | PowershellRM、ActiveNet、MSI Afterburner（FluentDash11、HMNmeter2） |
| macOS 不提供的数据 | 温度、Apple 芯片的 CPU 频率、GPU 使用率和频率、显存 |
| 已不存在的网络服务 | 雅虎天气（Enigma）、weather.com XML 服务（Mini Weather、Nelamint、PogPack、Simple Clean） |
| 皮肤自身错误（Windows 上也一样） | 公式引用了 meter（PogPack）、开机时长文字中 “mm” 重复（Enigma）、把文字设置到不存在的 meter 上（FluentDash11） |
| 需要用户自行配置的内容 | 订阅地址、启动器目标、天气位置代码 |
| 仅与测试时长有关 | 较慢的网络请求（外网 IP）和较大的 `UpdateDivider` 在 App 中几秒后就会显示 |

没有发现任何崩溃、卡死或超时，也没有任何剩余差异被追溯到 Deskset 的渲染错误。主测试中唯一见到的引擎小问题——由节变量拼出的
MeterStyle 名称（Enigma 的阅读器和便笺标签页）在加载时记录 “MeterStyle … does not exist” 警告，尽管该样式能被正确找到并
绘制——在合并引擎接线之后已不再出现。

---

## 13. 已知缺口与计划

| 缺口 | 状态 | 说明 |
| --- | --- | --- |
| 硬件传感器（温度、风扇、电压、GPU 频率） | 不支持 | macOS 没有公开 API；计划在后续版本中提供 |
| 布局（`!LoadLayout`、应用已安装的布局） | 不支持 | 已安装的布局会保留，等这一功能推出后使用 |
| Aero 模糊（`Blur`、`BlurRegion`、模糊类 bang）、`!ResetStats` | 不支持 | 模糊效果请用 FrostedGlass |
| 保存的窗口锚点（`!SetAnchor`；保存的位置记住锚点） | 部分支持 | 锚点只在摆放皮肤时应用一次；改变尺寸的皮肤向右、向下扩展 |
| `DragGroup`；点击穿透皮肤上的 Ctrl / ⌘ 临时覆盖 | 不支持 | 请在菜单或管理窗口中关闭点击穿透 |
| 自定义光标（`.cur` / `.ani`、大多数光标名称） | 部分支持 | 显示箭头 |
| WindowMessage、VirtualDesktops | 不支持 | macOS 上没有对应物 |
| 其他 Windows 插件 DLL | 不支持 | 数值为 0 / 空，皮肤的兼容性提示中有说明 |
| 单个 App 的音量（AppVolume `SetVolume`） | 不支持 | macOS 没有单个 App 的音量 |
| 浏览器媒体（WebNowPlaying 扩展） | 不支持 | 改为显示 Music 和 Spotify |
| Lua `os.execute` shell 命令 | 部分支持 | `os.execute` 只能打开文件和网址；请用 RunCommand |
| `.rar` / `.7z` 包 | 不支持 | 先解压，再安装文件夹 |
| Windows 图标字体（Segoe MDL2 / Fluent Icons） | 不支持 | 在 `@Resources` 中附带图标字体或图片 |
| 冷门 PCRE 特性（递归、回溯控制动词） | 部分支持 | 常见写法可用 |

---

## 14. 资料来源与方法

- Rainmeter 手册：<https://docs.rainmeter.net/manual/>（皮肤、变量、公式、meter、measure、插件、bang、分发与安装皮肤），
  以及其技巧页面和版本历史。
- 第三方插件公开的 README 和使用说明页面（AppVolume、WebNowPlaying、FrostedGlass、Chameleon、SysColor、IsFullScreen、
  GetActiveTitle、Mouse 以及它的第 2 版 Slider）。
- Apple 关于 Core Audio、CoreWLAN、AppKit、ScreenCaptureKit 的文档，以及 Music 和 Spotify 的 AppleScript 词典。
- 对真实皮肤及其作者截图的观察，仅在本地测试。

Deskset 是净室实现：没有阅读或使用任何 Rainmeter 或插件的源代码。“Rainmeter” 是其所有者的商标；Deskset 是兼容 Rainmeter
皮肤的独立产品。

各领域的说明会随代码更新：[`compat/engine.md`](compat/engine.md)、[`compat/lua.md`](compat/lua.md)、
[`compat/plugins.md`](compat/plugins.md)、[`compat/audio.md`](compat/audio.md)、[`compat/media-ui.md`](compat/media-ui.md)、
[`compat/installer.md`](compat/installer.md)、[`compat/app.md`](compat/app.md)。这些文件和本文档描述的是当前行为。
