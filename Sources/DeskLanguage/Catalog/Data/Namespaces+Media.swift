import Foundation

// Music, volume, sound.

extension CatalogData {
    static let mediaNamespaces: [NamespaceSpec] = [musicNamespace, volumeNamespace, audioNamespace, microphoneNamespace]

    static func nowPlaying(_ type: String) -> DataLowering { pluginKernel("NowPlaying", ["PlayerType": type]) }
    static let nowPlayingAlternatives = [plugin("iTunesPlugin").approx(), plugin("WebNowPlaying").approx()]

    static func musicCommand(_ command: String) -> RainmeterMapping {
        bang("!CommandMeasure", "NowPlaying \(command)").approx("sent to a NowPlaying measure")
    }

    static let musicNamespace = namespace("music", "Music", "音乐", permission: "music", main: "title", [
        field("title", "Song title", "歌名", .string, cadence: .event, lower: nowPlaying("Title"),
              preview: #""Starlight (Live at the Royal Albert Hall)""#,
              doc: doc("The current track in Music or Spotify; missing when nothing plays", "正在播放的歌名",
                       #"Text(music.title.ifMissing("Nothing playing"))"#,
                       [plugin("NowPlaying", "PlayerType", "Title")] + nowPlayingAlternatives,
                       keywords: ["Title", "NowPlaying", "song", "track", "title", "now playing", "song title", "歌名"], rank: 80)),
        field("artist", "Artist", "歌手", .string, cadence: .event, lower: nowPlaying("Artist"),
              preview: #""The Mountain Goats and Friends""#,
              doc: doc("The current track's artist; missing when nothing plays", "正在播放的歌手", "Text(music.artist)",
                       [plugin("NowPlaying", "PlayerType", "Artist")] + nowPlayingAlternatives,
                       keywords: ["Artist", "NowPlaying", "singer", "band", "artist", "歌手"], rank: 70)),
        field("album", "Album", "专辑", .string, cadence: .event, lower: nowPlaying("Album"),
              preview: #""The Sunset Tree (Deluxe Edition)""#,
              doc: doc("The current track's album; missing when nothing plays", "正在播放的专辑", "Text(music.album)",
                       [plugin("NowPlaying", "PlayerType", "Album")] + nowPlayingAlternatives,
                       keywords: ["Album", "NowPlaying", "record", "album", "专辑"], rank: 55)),
        field("cover", "Album cover", "专辑封面", .imageSource, cadence: .event, lower: nowPlaying("Cover"),
              doc: doc("The album cover", "专辑封面", "Image(music.cover).size(64).rounded(8)",
                       [plugin("NowPlaying", "PlayerType", "Cover")],
                       keywords: ["Cover", "NowPlaying", "artwork", "album art", "cover art", "专辑封面"], rank: 65)),
        field("playing", "Playing", "是否在播放", .bool, cadence: .event, twin: "music.play()", lower: nowPlaying("State"),
              doc: doc("Whether something is playing; false when nothing is", "是否正在播放；没有播放时是 false",
                       #"Icon("pause.fill").hidden(if: not music.playing)"#, [plugin("NowPlaying", "PlayerType", "State")],
                       keywords: ["State", "NowPlaying", "playing", "is playing", "paused", "正在播放"], rank: 60)),
        field("position", "Position in the track", "播放位置", .duration, range: .member("duration"),
              format: .style(".clock"), cadence: .periodic(seconds: 1), settable: true, lower: nowPlaying("Position"),
              doc: doc("Where the track is; it can be assigned (seeks)", "播放到哪里；可以赋值（跳转）",
                       #"Text("{music.position} / {music.duration}")"#, [plugin("NowPlaying", "PlayerType", "Position")],
                       keywords: ["Position", "NowPlaying", "elapsed", "current time", "播放位置"], rank: 45)),
        field("duration", "Track length", "歌曲长度", .duration, format: .style(".clock"), cadence: .event,
              lower: nowPlaying("Duration"),
              doc: doc("The track's length", "歌曲长度", #"Text("{music.duration}")"#,
                       [plugin("NowPlaying", "PlayerType", "Duration")],
                       keywords: ["Duration", "NowPlaying", "length", "track length", "时长"], rank: 40)),
        field("progress", "Track progress", "播放进度", .percent, range: .fixed(0...100), cadence: .periodic(seconds: 1),
              lower: nowPlaying("Progress"),
              doc: doc("How far the track is", "播放进度", "Progress(music.progress)",
                       [plugin("NowPlaying", "PlayerType", "Progress")],
                       keywords: ["Progress", "NowPlaying", "progress", "played", "播放进度"], rank: 50)),
        field("player", "Player", "播放器", .string, cadence: .event, lower: nativeKernel("nowPlaying", field: "player"),
              doc: doc("\"Music\" or \"Spotify\"", "当前播放器", "Text(music.player)", [plugin("NowPlaying", "PlayerName")],
                       keywords: ["PlayerName", "NowPlaying", "player", "app", "播放器"], rank: 30)),
        field("shuffle", "Shuffle", "随机播放", .bool, cadence: .event, lower: nowPlaying("Shuffle"),
              doc: doc("Whether shuffle is on", "是否随机播放", ".color(.accent, if: music.shuffle)",
                       [plugin("NowPlaying", "PlayerType", "Shuffle")],
                       keywords: ["Shuffle", "NowPlaying", "shuffle", "random", "随机播放"], rank: 25)),
        field("repeat", "Repeat", "重复播放", .bool, cadence: .event, lower: nowPlaying("Repeat"),
              doc: doc("Whether repeat is on", "是否重复播放", ".color(.accent, if: music.repeat)",
                       [plugin("NowPlaying", "PlayerType", "Repeat")],
                       keywords: ["Repeat", "NowPlaying", "repeat", "loop", "重复播放"], rank: 25)),
        dataAction("play", "Play", "播放", command: "Play",
                   doc: doc("Starts playing in Music or Spotify", "在“音乐”或 Spotify 里开始播放", ".onClick { music.play() }",
                            [musicCommand("Play")], keywords: ["Play", "play", "start", "resume", "播放"], rank: 50)),
        dataAction("pause", "Pause", "暂停", command: "Pause",
                   doc: doc("Pauses Music or Spotify", "暂停“音乐”或 Spotify", ".onClick { music.pause() }",
                            [musicCommand("Pause")], keywords: ["Pause", "pause", "stop", "暂停"], rank: 45)),
        dataAction("playPause", "Play or pause", "播放或暂停", command: "PlayPause",
                   doc: doc("Plays or pauses Music or Spotify", "播放或暂停“音乐”或 Spotify", ".onClick { music.playPause() }",
                            [musicCommand("PlayPause"), plugin("MediaKey")],
                            keywords: ["PlayPause", "MediaKey", "toggle", "play pause", "播放暂停"], rank: 60)),
        dataAction("next", "Next track", "下一首", command: "Next",
                   doc: doc("Skips to the next track", "跳到下一首", ".onClick { music.next() }",
                            [musicCommand("Next"), plugin("MediaKey")], keywords: ["Next", "skip", "forward", "下一首"], rank: 55)),
        dataAction("previous", "Previous track", "上一首", command: "Previous",
                   doc: doc("Goes back to the previous track", "回到上一首", ".onClick { music.previous() }",
                            [musicCommand("Previous"), plugin("MediaKey")], keywords: ["Previous", "back", "prev", "上一首"],
                            rank: 45)),
        dataAction("openPlayer", "Open the player", "打开播放器", command: "OpenPlayer",
                   doc: doc("Opens Music or Spotify", "打开“音乐”或 Spotify", ".onClick { music.openPlayer() }",
                            [musicCommand("OpenPlayer")], keywords: ["OpenPlayer", "open player", "打开播放器"], rank: 25)),
        dataAction("seek", "Jump to", "跳到", [sig(
            arg("to", .duration, required: true, preview: "0s", "The position to jump to", "要跳到的位置"))],
                   command: "SetPosition",
                   doc: doc("Jumps to a position (same as assigning music.position)", "跳到某个位置", ".onClick { music.seek(to: 0s) }",
                            [musicCommand("SetPosition")], keywords: ["SetPosition", "seek", "jump", "scrub", "跳转"], rank: 25)),
    ], doc: doc("What's playing in Music or Spotify", "“音乐”或 Spotify 正在播放的内容", "Text(music.title)",
                [plugin("NowPlaying")], keywords: ["NowPlaying", "music", "now playing", "音乐"], rank: 80))

    static func win7Audio(_ command: String) -> RainmeterMapping {
        bang("!CommandMeasure", "Win7AudioPlugin \(command)").approx("sent to a Win7Audio measure")
    }

    static let volumeNamespace = namespace("volume", "Volume", "音量", main: "level", [
        field("level", "Volume", "音量", .percent, range: .fixed(0...100), cadence: .event, sync: true, settable: true,
              lower: pluginKernel("Win7AudioPlugin"),
              doc: doc("Output volume; it can be assigned", "系统音量；可以赋值", "Slider(volume.level)",
                       [plugin("Win7AudioPlugin")],
                       keywords: ["Win7AudioPlugin", "volume", "sound level", "loudness", "音量"], rank: 60)),
        field("muted", "Muted", "静音", .bool, cadence: .event, sync: true, settable: true,
              lower: pluginKernel("Win7AudioPlugin", field: "muted"),
              doc: doc("Whether sound is muted; it can be assigned", "是否静音；可以赋值",
                       #"Icon("speaker.slash.fill").hidden(if: not volume.muted)"#,
                       [plugin("Win7AudioPlugin").approx("its mute state")],
                       keywords: ["Win7AudioPlugin", "mute", "muted", "silent", "静音"], rank: 45)),
        field("device", "Output device", "输出设备", .string, cadence: .event, sync: true,
              lower: pluginKernel("AudioLevel", ["Type": "DeviceName"]), preview: #""External Headphones (USB-C)""#,
              doc: doc("The output device's name", "输出设备名称", "Text(volume.device)",
                       [plugin("AudioLevel", "Type", "DeviceName")],
                       keywords: ["DeviceName", "AudioLevel", "output device", "speakers", "headphones", "输出设备"], rank: 30)),
        dataAction("set", "Set the volume", "设置音量", [sig(
            pos("level", .percent, range: 0...100, preview: "50%", "The new volume", "新的音量"))], command: "SetVolume",
                   doc: doc("Changes the output volume", "调节系统音量", ".onScroll(.up) { volume.set(volume.level + 5%) }",
                            [win7Audio("SetVolume")], keywords: ["SetVolume", "set volume", "change volume", "调音量"], rank: 35)),
        dataAction("mute", "Mute", "静音", command: "Mute",
                   doc: doc("Mutes the output", "静音", ".onClick { volume.mute() }", [win7Audio("Mute")],
                            keywords: ["Mute", "mute", "silence", "静音"], rank: 30)),
        dataAction("unmute", "Unmute", "取消静音", command: "Unmute",
                   doc: doc("Turns the sound back on", "取消静音", ".onClick { volume.unmute() }", [win7Audio("Unmute")],
                            keywords: ["Unmute", "unmute", "取消静音"], rank: 25)),
        dataAction("toggleMute", "Mute or unmute", "静音或取消静音", command: "ToggleMute",
                   doc: doc("Mutes or unmutes the output", "在静音和有声之间切换", ".onClick { volume.toggleMute() }",
                            [win7Audio("ToggleMute")], keywords: ["ToggleMute", "toggle mute", "切换静音"], rank: 35)),
    ], doc: doc("The Mac's output volume", "系统音量", "Slider(volume.level)", [plugin("Win7AudioPlugin")],
                keywords: ["Win7AudioPlugin", "volume", "sound", "音量"], rank: 60))

    static func audioMembers(port: String, what: String, whatZh: String) -> [MemberSpec] {
        func level(_ type: String, channel: String? = nil) -> DataLowering {
            var options = ["Port": port, "Type": type]
            if let channel { options["Channel"] = channel }
            return pluginKernel("AudioLevel", options)
        }
        let prefix = port == "Input" ? "audio.microphone" : "audio"
        return [
            dataFunction("bands", "Sound bands", "频段响度", [sig(
                pos("count", .plainNumber, range: 1...128, whole: true, preview: "32", "How many frequency bands", "分成多少个频段"))],
                         list(.plainNumber), range: .fixed(0...1), max: .argument("_"), cadence: .frame,
                         lower: .measure(type: "Plugin", options: ["Plugin": .literal("AudioLevel"), "Port": .literal(port),
                                                                   "Type": .literal("Band"), "Bands": argument()], field: nil),
                         doc: doc("Loudness of count frequency bands of \(what), each from 0 to 1", "\(whatZh)分成若干频段的响度，每个 0 到 1",
                                  "for level in \(prefix).bands(32) { Capsule().size(4, level * 40) }",
                                  [plugin("AudioLevel", "Type", "Band"), plugin("AudioLevel", "Bands")],
                                  keywords: ["Band", "AudioLevel", "spectrum", "equalizer", "visualizer", "fft", "频谱"], rank: 45)),
            field("level", "Loudness", "响度", .plainNumber, range: .fixed(0...1), cadence: .frame, lower: level("RMS"),
                  doc: doc("Overall loudness of \(what), from 0 to 1 (compare with 50% or 0.5)", "\(whatZh)的整体响度，0 到 1",
                           "Progress(\(prefix).level)", [plugin("AudioLevel", "Type", "RMS")],
                           keywords: ["RMS", "AudioLevel", "loudness", "level", "vu", "响度"], rank: 45)),
            field("peak", "Peak", "峰值", .plainNumber, range: .fixed(0...1), cadence: .frame, lower: level("Peak"),
                  doc: doc("The peak loudness of \(what), from 0 to 1", "\(whatZh)的峰值，0 到 1", "Progress(\(prefix).peak)",
                           [plugin("AudioLevel", "Type", "Peak")], keywords: ["Peak", "AudioLevel", "peak", "峰值"], rank: 30)),
            field("left", "Left channel", "左声道", .plainNumber, range: .fixed(0...1), cadence: .frame,
                  lower: level("RMS", channel: "L"),
                  doc: doc("The loudness of the left channel of \(what)", "\(whatZh)左声道的响度", "Progress(\(prefix).left)",
                           [plugin("AudioLevel", "Channel", "L")], keywords: ["Channel", "AudioLevel", "left", "左声道"], rank: 25)),
            field("right", "Right channel", "右声道", .plainNumber, range: .fixed(0...1), cadence: .frame,
                  lower: level("RMS", channel: "R"),
                  doc: doc("The loudness of the right channel of \(what)", "\(whatZh)右声道的响度", "Progress(\(prefix).right)",
                           [plugin("AudioLevel", "Channel", "R")], keywords: ["Channel", "AudioLevel", "right", "右声道"], rank: 25)),
        ]
    }

    static let audioNamespace = namespace("audio", "Sound", "声音", permission: "systemAudio", main: "level",
        audioMembers(port: "Output", what: "the sound the Mac plays", whatZh: "系统正在播放的声音"),
        doc: doc("The sound the Mac plays", "这台 Mac 播放的声音", "Progress(audio.level)", [plugin("AudioLevel")],
                 keywords: ["AudioLevel", "sound", "audio", "声音"], rank: 45))

    static let microphoneNamespace = namespace("audio.microphone", "Microphone", "麦克风", permission: "microphone",
                                                main: "level",
        audioMembers(port: "Input", what: "the microphone", whatZh: "麦克风的声音"),
        doc: doc("The same for the microphone", "麦克风的同样数据", "Progress(audio.microphone.level)",
                 [plugin("AudioLevel", "Port", "Input")], keywords: ["Input", "AudioLevel", "microphone", "mic", "麦克风"],
                 rank: 25))
}
