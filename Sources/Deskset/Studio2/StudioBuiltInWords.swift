import Foundation

/// The built-in widgets' names and first sentences in Chinese: the widget page's title and the sentence under it read
/// the widget's `[Metadata]`, which the Stationery suite writes in English. A widget made by someone else keeps its own
/// words; so does a built-in one whose sentence was changed.
enum StudioBuiltInWords {
    /// The root folder of the built-in suite.
    static let suite = "Stationery"

    /// The widget's name in the Studio's language ("System" → "系统" in Chinese, for a built-in widget).
    static func name(_ name: String, root: String) -> String {
        guard StudioText.language == .chinese, root.caseInsensitiveCompare(suite) == .orderedSame else { return name }
        return names[name] ?? name
    }

    /// The first sentence of a built-in widget's description in the Studio's language.
    static func sentence(_ sentence: String, root: String) -> String {
        guard StudioText.language == .chinese, root.caseInsensitiveCompare(suite) == .orderedSame else { return sentence }
        return sentences[sentence] ?? sentence
    }

    static let names: [String: String] = [
        "Almanac": "历书", "Analog Clock": "指针时钟", "Battery": "电池", "Calendar": "日历", "Chronograph": "计时码表",
        "Clock": "时钟", "Countdown": "倒数日", "Daybreak": "破晓", "Launcher": "快捷启动", "Network": "网络",
        "Now Playing": "正在播放", "Photo Frame": "相框", "Sentence Clock": "整句时钟", "Spectrum": "频谱",
        "Storage": "存储空间", "Studio VU": "录音棚 VU 表", "System": "系统", "Temperature": "温度", "Timer": "计时器",
        "To Do": "待办事项", "Turntable": "黑胶唱机", "Weather": "天气", "World Clock": "世界时钟",
    ]

    static let sentences: [String: String] = [
        "The date as an almanac's masthead, straight on the wallpaper: the year's progress as a rule (one dot per week left), the week, the day of the year, the days to New Year, and sunrise and sunset worked out on your Mac for the suite's place.":
            "像历书报头那样把日期直接写在墙纸上：一条标尺表示今年过了多少（剩下的每周一个点），还有第几周、第几天、离新年几天，以及在你的 Mac 上算出的日出和日落。",
        "An analog clock.": "一只指针时钟。",
        "Your Mac's battery: charge, charging state and time left, with its health, cycles, temperature, power flow and adapter.":
            "你的 Mac 的电池：电量、充电状态和剩余时间，还有健康度、循环次数、温度、电流和电源适配器。",
        "Your Mac's battery: charge, charging state and time left.": "你的 Mac 的电池：电量、充电状态和剩余时间。",
        "Today and this month at a glance: the weekday, the day, the week and the moon beside the month.":
            "一眼看完今天和这个月：星期、日期、第几周，月历旁边还有月相。",
        "This month at a glance.": "一眼看完这个月。",
        "A three-register watch: the weather at 9 (today's low to high, the dot at now), the battery as a power reserve at 3 (the CPU on a Mac without a battery), running seconds at 6 and the date under 12.":
            "一只三眼表：9 点位是天气（今天的最低到最高，点是现在），3 点位把电池当作动力储存（没有电池的 Mac 显示 CPU），6 点位是小秒针，12 点下面是日期。",
        "The time and the date, with today's sunrise, sunset, day length and moon, worked out on your Mac.":
            "时间和日期，还有今天的日出、日落、昼长和月相，都在你的 Mac 上算出。",
        "The time, the date and the sun: the next sunrise or sunset, worked out on your Mac.":
            "时间、日期和太阳：下一次日出或日落，在你的 Mac 上算出。",
        "Days to a date that matters: New Year until you choose your own event.":
            "离一个重要日子还有几天：在你选好自己的日子之前是新年。",
        "A lock-screen clock with a 24-hour daylight ruler, straight on the wallpaper: the night dotted, the day a band in the colours of the sky, the sun (or the moon) at the time it is now.":
            "像锁屏那样的时钟，下面一条 24 小时的日光标尺，直接写在墙纸上：夜晚是点，白天是天空颜色的色带，太阳（或月亮）在现在的时刻。",
        "The Mac things you reach for, on the desktop: apps, folders, files, links, shortcuts and the Trash.":
            "常用的东西放在桌面上：App、文件夹、文件、链接、快捷指令和废纸篓。",
        "Download and upload speed, with a two-minute graph.": "下载和上传速度，还有两分钟的曲线。",
        "What Music or Spotify is playing, with play, pause and skip.": "“音乐”或 Spotify 正在播放的曲目，可以播放、暂停和跳过。",
        "Photos from a folder on your Mac, a new one every 10 minutes.": "你的 Mac 上一个文件夹里的照片，每 10 分钟换一张。",
        "The time as a sentence: the words that say it are lit, the rest stay dim, and the footer gives the exact time and the date.":
            "用一句话说出时间：说出时间的字亮起，其余的字暗着，底部是精确的时间和日期。",
        "Spectrum draws the sound your Mac plays: 32 bars from 40 Hz on the left to 16 kHz on the right (the Strip: 64 bars, no card).":
            "把你的 Mac 播放的声音画出来：32 根柱子，左边 40 Hz，右边 16 kHz（长条：64 根柱子，没有卡片）。",
        "How much space your disks have: the startup disk and any disk you connect.":
            "你的磁盘还有多少空间：启动磁盘和你接上的每个磁盘。",
        "How much space a disk has: the startup disk, or the one chosen in the menu.":
            "一个磁盘还有多少空间：启动磁盘，或菜单里选的那个。",
        "A stereo pair of VU meters that swing with whatever your Mac plays, with the track from Music or Spotify under them.":
            "一对立体声 VU 表，随你的 Mac 播放的声音摆动，下面是“音乐”或 Spotify 正在播放的曲目。",
        "CPU, memory, disk and GPU at a glance, the CPU's last 5 minutes (or every core's load) and the busiest processes.":
            "一眼看完 CPU、内存、磁盘和 GPU，还有 CPU 最近 5 分钟（或每个核心的负载）和最忙的进程。",
        "CPU, memory, disk and GPU at a glance.": "一眼看完 CPU、内存、磁盘和 GPU。",
        "CPU and memory at a glance; the tooltip adds the disk, the GPU and the uptime.":
            "一眼看完 CPU 和内存；悬停提示里还有磁盘、GPU 和开机时间。",
        "How hot the Mac is, and whether macOS is slowing it down to cool it: CPU temperature and thermal state, fans and power (Medium: GPU and SSD temperatures and an 11-minute CPU history).":
            "Mac 有多热，macOS 有没有为了降温而降速：CPU 温度和散热状态、风扇和功率（中号：GPU 和 SSD 温度，以及 CPU 最近 11 分钟）。",
        "A countdown timer with 5, 15, 25 and 45-minute presets.": "一个倒计时器，预设 5、15、25 和 45 分钟。",
        "A short to-do list that stays on this Mac, in Deskset's settings folder (Stationery.inc); it does not sync with Reminders or iCloud.":
            "一张留在这台 Mac 上的短待办清单，存在 Deskset 的设置文件夹里（Stationery.inc）；不和“提醒事项”或 iCloud 同步。",
        "What Music or Spotify is playing, as a record deck: the cover is the label, the record takes the cover's colour and the tonearm shows how far the song has played.":
            "把“音乐”或 Spotify 正在播放的曲目做成唱机：封面是唱片标签，唱片取封面的颜色，唱臂表示这首歌放到了哪里。",
        "The weather for one place: now, the next six hours and (Large) six days.": "一个地方的天气：现在、接下来六小时和（大号）六天。",
        "Four clocks: this Mac's time and three cities, each dial white by day and dark by night there.":
            "四只时钟：这台 Mac 的时间和三个城市，每个表盘在当地白天是白色，夜里是深色。",
        "The time in three cities, with their offsets from here and day or night there.":
            "三个城市的时间，还有它们和这里的时差，以及当地是白天还是夜里。",
    ]
}
