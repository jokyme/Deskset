import Foundation

// Permissions a widget declares in `info { permissions: […] }`, the features `supports(…)` asks about, the commands
// that run an argument as code (DK8209), and the Rainmeter details a converted widget may keep with `.rainmeter(…)`.

extension CatalogData {
    static func permission(_ id: String, prompt: String?, needs: (String, String), neededBy: [String], _ en: String,
                           _ zh: String, keywords: [String], rank: Int) -> PermissionSpec {
        PermissionSpec(id: id, systemPrompt: prompt, needsPhrase: L(needs.0, needs.1), neededBy: neededBy,
                       doc: doc(en, zh, "permissions: [.\(id)]", keywords: keywords, rank: rank))
    }

    /// `needsPhrase` completes "This widget …" / "这个组件要……" (DK8101 and the install dialog).
    static let permissions: [PermissionSpec] = [
        permission("music", prompt: "Automation (control Music / Spotify)",
                   needs: ("reads and controls what's playing", "读取和控制正在播放的音乐"), neededBy: ["music.*"],
                   "Read and control what's playing in Music or Spotify", "读取和控制“音乐”或 Spotify 正在播放的内容",
                   keywords: ["automation", "now playing", "音乐"], rank: 60),
        permission("location", prompt: "Location Services",
                   needs: ("uses this Mac's approximate location", "使用这台 Mac 的大致位置"),
                   neededBy: ["weather.*", "sun.*", "wifi.name"],
                   "This Mac's approximate location, for the weather, the sun and the Wi-Fi name",
                   "这台 Mac 的大致位置，用于天气、太阳和 Wi-Fi 名称", keywords: ["location services", "gps", "位置", "定位"], rank: 55),
        permission("calendar", prompt: "Calendars", needs: ("reads your calendar events", "读取你的日历日程"),
                   neededBy: ["calendar.events"], "Read events from Calendar", "读取日历里的日程",
                   keywords: ["calendars", "events", "日历"], rank: 40),
        permission("microphone", prompt: "Microphone", needs: ("listens to the microphone", "听麦克风的声音"),
                   neededBy: ["audio.microphone.*"], "Listen to the microphone", "听麦克风的声音",
                   keywords: ["mic", "input", "麦克风"], rank: 25),
        permission("systemAudio", prompt: "System audio recording",
                   needs: ("listens to the sound your Mac plays", "听这台 Mac 播放的声音"), neededBy: ["audio.*"],
                   "Listen to the sound this Mac plays", "听这台 Mac 播放的声音",
                   keywords: ["system audio", "audio capture", "声音"], rank: 35),
        permission("commands", prompt: nil, needs: ("runs commands on your Mac", "在你的 Mac 上运行命令"),
                   neededBy: ["command", "run"], "Run commands; Deskset lists them when the widget is installed",
                   "运行命令；安装时 Deskset 会列出这些命令", keywords: ["shell", "scripts", "terminal", "命令"], rank: 30),
        permission("notifications", prompt: "Notifications", needs: ("shows notifications", "发送通知"),
                   neededBy: ["notify"], "Show notifications", "发送通知", keywords: ["alerts", "notify", "通知"], rank: 30),
        permission("files", prompt: "the folder prompt for protected folders",
                   needs: ("reads a folder's contents", "读取文件夹里的内容"), neededBy: ["files", "folder"],
                   "Read the contents of a folder", "读取文件夹里的内容", keywords: ["folders", "disk access", "文件"], rank: 30),
        permission("accessibility", prompt: "Accessibility (in System Settings)",
                   needs: ("reads window titles of other apps", "读取其他 App 的窗口标题"),
                   neededBy: ["apps.frontmost.windowTitle"], "Read the window titles of other apps", "读取其他 App 的窗口标题",
                   keywords: ["window titles", "辅助功能"], rank: 15),
    ]

    static let features: [FeatureSpec] = [
        FeatureSpec(id: "liquidGlass", availability: "macOS 26 or later", minimumMacOS: 26,
                    fallback: L(".glass is drawn with the blur materials of macOS 13–15 automatically",
                                ".glass 会自动改用 macOS 13–15 的毛玻璃效果"),
                    doc: doc("Liquid Glass (macOS 26 or later)", "液态玻璃（macOS 26 起）",
                             ".background(.glass, if: supports(.liquidGlass))",
                             keywords: ["glass", "Liquid Glass", "液态玻璃"], mac: true, macOS: 26, rank: 40)),
        FeatureSpec(id: "symbolEffects", availability: "macOS 14 or later (some effects 15)", minimumMacOS: 14,
                    fallback: L(".iconEffect does nothing", ".iconEffect 不起作用"),
                    doc: doc("SF Symbol animations (macOS 14 or later)", "SF 符号动效（macOS 14 起）",
                             #"Icon("wifi").iconEffect(.pulse).hidden(if: not supports(.symbolEffects))"#,
                             keywords: ["symbol effects", "animation", "动效"], mac: true, macOS: 14, rank: 25)),
        FeatureSpec(id: "sensors", availability: "the sensor service can read this Mac",
                    fallback: L("sensors.* read missing", "sensors.* 取不到值"),
                    doc: doc("Hardware sensors this Mac lets Deskset read", "Deskset 能在这台 Mac 上读到的硬件传感器",
                             #"Text("{sensors.cpuTemperature}").hidden(if: not supports(.sensors))"#,
                             keywords: ["temperature", "fans", "传感器"], mac: true, rank: 25)),
    ]

    /// Commands that read one of their arguments as code: an option value placed there would run as code a second
    /// time (DK8209). `codeFlag` nil: every argument is code.
    static let rereadingCommands: [RereadSpec] = [
        RereadSpec(command: "eval", codeFlag: nil), RereadSpec(command: "source", codeFlag: nil),
        RereadSpec(command: ".", codeFlag: nil),
        RereadSpec(command: "sh", codeFlag: "-c"), RereadSpec(command: "bash", codeFlag: "-c"),
        RereadSpec(command: "zsh", codeFlag: "-c"), RereadSpec(command: "dash", codeFlag: "-c"),
        RereadSpec(command: "ksh", codeFlag: "-c"), RereadSpec(command: "fish", codeFlag: "-c"),
        RereadSpec(command: "osascript", codeFlag: "-e"),
        RereadSpec(command: "python3", codeFlag: "-c"), RereadSpec(command: "python", codeFlag: "-c"),
        RereadSpec(command: "perl", codeFlag: "-e"), RereadSpec(command: "ruby", codeFlag: "-e"),
        RereadSpec(command: "node", codeFlag: "-e"), RereadSpec(command: "php", codeFlag: "-r"),
        RereadSpec(command: "ssh", codeFlag: nil),
        RereadSpec(command: "su", codeFlag: "-c"),
    ]

    /// The Rainmeter details a converted widget may keep with `.rainmeter(option, value)` (D127): only what Deskset's
    /// renderer draws for a converted meter and Desk has no modifier for. Any other Rainmeter option is DK5027.
    /// Details of `[Rainmeter]` go on the outermost element.
    static let compatDetails: [CompatDetailSpec] = [
        CompatDetailSpec(key: "AntiAlias", owner: .meter(type: ""), appliesTo: .all, type: .bool, prop: "compat.antiAlias"),
        CompatDetailSpec(key: "AccurateText", owner: .skin, appliesTo: .all, type: .bool, prop: "compat.accurateText"),
        CompatDetailSpec(key: "TransformationMatrix", owner: .meter(type: ""), appliesTo: .all, type: .string,
                         prop: "compat.transformationMatrix"),
        CompatDetailSpec(key: "BevelType", owner: .meter(type: ""), appliesTo: .all, type: .plainNumber, prop: "compat.bevelType"),
        CompatDetailSpec(key: "BevelColor", owner: .meter(type: ""), appliesTo: .all, type: .color, prop: "compat.bevelColor"),
        CompatDetailSpec(key: "BevelColor2", owner: .meter(type: ""), appliesTo: .all, type: .color, prop: "compat.bevelColor2"),
        CompatDetailSpec(key: "BackgroundMargins", owner: .skin, appliesTo: .all, type: .string,
                         prop: "compat.backgroundMargins"),
        CompatDetailSpec(key: "TrailingSpaces", owner: .meter(type: "String"), appliesTo: .textLike, type: .bool,
                         prop: "compat.trailingSpaces"),
        CompatDetailSpec(key: "UseExifOrientation", owner: .meter(type: "Image"), appliesTo: .of(.image), type: .bool,
                         prop: "compat.useExifOrientation"),
        CompatDetailSpec(key: "MaskImageName", owner: .meter(type: "Image"), appliesTo: .of(.image), type: .imageSource,
                         prop: "compat.maskImage"),
        CompatDetailSpec(key: "MaskImageFlip", owner: .meter(type: "Image"), appliesTo: .of(.image), type: .string,
                         prop: "compat.maskImageFlip"),
        CompatDetailSpec(key: "MaskImageRotate", owner: .meter(type: "Image"), appliesTo: .of(.image), type: .plainNumber,
                         prop: "compat.maskImageRotate"),
        CompatDetailSpec(key: "GraphStart", owner: .meter(type: "Line"), appliesTo: .of(.graph), type: .string,
                         prop: "compat.graphStart"),
        CompatDetailSpec(key: "GraphOrientation", owner: .meter(type: "Line"), appliesTo: .of(.graph), type: .string,
                         prop: "compat.graphOrientation"),
        CompatDetailSpec(key: "HorizontalLines", owner: .meter(type: "Line"), appliesTo: .of(.graph), type: .bool,
                         prop: "compat.horizontalLines"),
        CompatDetailSpec(key: "HorizontalLineColor", owner: .meter(type: "Line"), appliesTo: .of(.graph), type: .color,
                         prop: "compat.horizontalLineColor"),
        CompatDetailSpec(key: "TransformStroke", owner: .meter(type: "Line"), appliesTo: .of(.graph), type: .string,
                         prop: "compat.transformStroke"),
        CompatDetailSpec(key: "LineStart", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .plainNumber,
                         prop: "compat.lineStart"),
        CompatDetailSpec(key: "LineLength", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .plainNumber,
                         prop: "compat.lineLength"),
        CompatDetailSpec(key: "ControlAngle", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .bool,
                         prop: "compat.controlAngle"),
        CompatDetailSpec(key: "ControlStart", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .bool,
                         prop: "compat.controlStart"),
        CompatDetailSpec(key: "ControlLength", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .bool,
                         prop: "compat.controlLength"),
        CompatDetailSpec(key: "StartShift", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .plainNumber,
                         prop: "compat.startShift"),
        CompatDetailSpec(key: "LengthShift", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .plainNumber,
                         prop: "compat.lengthShift"),
        CompatDetailSpec(key: "ValueRemainder", owner: .meter(type: "Roundline"), appliesTo: .of(.gauge), type: .plainNumber,
                         prop: "compat.valueRemainder"),
        CompatDetailSpec(key: "OffsetX", owner: .meter(type: "Rotator"), appliesTo: .of(.gauge, .image), type: .plainNumber,
                         prop: "compat.rotatorOffsetX"),
        CompatDetailSpec(key: "OffsetY", owner: .meter(type: "Rotator"), appliesTo: .of(.gauge, .image), type: .plainNumber,
                         prop: "compat.rotatorOffsetY"),
        // Combine, Skew, line caps and joins of a Shape meter: the whole shape definition is kept as written.
        CompatDetailSpec(key: "Shape", owner: .meter(type: "Shape"), appliesTo: .shapes, type: .string,
                         prop: "compat.shapeDefinition"),
    ]
}
