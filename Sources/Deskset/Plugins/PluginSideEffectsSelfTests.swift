import Foundation
import DesksetCore

/// The app's plugins on the side-effects seam (the engine's SideEffects.swift): under a recording, what Win7Audio,
/// AppVolume, NowPlaying, iTunes, WebNowPlaying and MediaKey would change on the Mac is recorded and nothing reaches the
/// audio devices, the players or the key events; with the live side effects the same commands go through as before.
enum PluginSideEffectsSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: side effects: the audio and media plugins' commands are recorded, not done") {
            let (skin, _) = try MediaUITests.bareSkin(t)
            let recording = RecordingSideEffects()
            skin.sideEffects = recording
            let section = MediaUITests.section

            // Win7Audio: its output controller is never asked.
            let win7 = Win7AudioMeasure(name: "W", section: section("W", []), skin: skin, type: "win7audioplugin")
            let output = AudioSelfTests.FakeOutput()
            win7.system = output
            win7.readOptions()
            for command in ["ChangeVolume -20", "ToggleMute", "SetOutputIndex 2", "SetVolume 35", "Nonsense 3"] {
                win7.execute(command: command)
            }
            t.equal(output.calls, [], "the output device is left alone")

            // AppVolume: the app is not even looked up.
            var lookups = 0
            let parent = AppVolumeMeasure(name: "P", section: section("P", []), skin: skin, type: "appvolume")
            parent.catalog = {
                lookups += 1
                return []
            }
            parent.readOptions()
            let child = AppVolumeMeasure(name: "A", section: section("A", [("Parent", "P"), ("AppName", "Spotify")]),
                                         skin: skin, type: "appvolume")
            child.parentLookup = { _ in parent }
            child.readOptions()
            for command in ["Mute", "ToggleMute", "UnMute"] { child.execute(command: command) }
            let indexed = AppVolumeMeasure(name: "B", section: section("B", [("Parent", "P"), ("Index", "2")]),
                                           skin: skin, type: "appvolume")
            indexed.parentLookup = { _ in parent }
            indexed.readOptions()
            indexed.execute(command: "Mute")
            t.equal(lookups, 0, "no app lookup")

            // NowPlaying, iTunes and WebNowPlaying: the player never gets the command.
            let backend = DemoNowPlayingBackend()
            backend.artworkEnabled = false
            let center = NowPlayingCenter(backend: backend)
            center.forceLive = true
            center.interval = 3600
            try MediaUITests.inline([center.worker]) {
                let nowPlaying = NowPlayingMeasure(name: "N", section: section("N", [("PlayerType", "Title")]),
                                                   skin: skin, type: "nowplaying")
                nowPlaying.center = center
                nowPlaying.readOptions()
                nowPlaying.execute(command: " PlayPause ")
                let itunes = ITunesMeasure(name: "I", section: section("I", [("Command", "PlayPause")]), skin: skin,
                                           type: "itunesplugin")
                itunes.center = center
                itunes.readOptions()
                itunes.execute(command: "")
                let web = WebNowPlayingMeasure(name: "WNP", section: section("WNP", [("PlayerType", "Title")]),
                                               skin: skin, type: "webnowplaying")
                web.center = center
                web.readOptions()
                web.execute(command: "Repeat")
                web.execute(command: "Explode")
            }
            t.equal(backend.performed.count, 0, "no player command")

            // MediaKey: no key event, no player, no volume change (its test sink would see each key).
            var sent: [MediaKeyCommand] = []
            MediaKeyMeasure.sink = { command, _ in sent.append(command) }
            defer { MediaKeyMeasure.sink = nil }
            let key = MediaKeyMeasure(name: "K", section: section("K", []), skin: skin, type: "mediakey")
            key.execute(command: "PrevTrack")
            key.execute(command: "volumeup")
            key.execute(command: "Explode")
            t.equal(sent, [], "no key sent")

            t.equal(recording.records, [
                .audio(.changeVolume(-20)), .audio(.toggleMute), .audio(.selectOutput(2)), .audio(.setVolume(35)),
                .audio(.muteApp("Spotify")), .audio(.toggleMuteApp("Spotify")), .audio(.unmuteApp("Spotify")),
                .audio(.muteApp("Index 2")),
                .media(plugin: "NowPlaying", command: "PlayPause"), .media(plugin: "iTunes", command: "PlayPause"),
                .media(plugin: "WebNowPlaying", command: "Repeat"),
                .mediaKey("PrevTrack"), .mediaKey("VolumeUp"),
            ], "exactly the commands the skin gave, unknown ones left out")

            // Live side effects: the same commands go through, as before the seam.
            skin.sideEffects = LiveSideEffects.shared
            win7.execute(command: "ToggleMute")
            t.equal(output.calls, ["mute true"], "live: the output device is changed")
            key.execute(command: "NextTrack")
            t.equal(sent, [.nextTrack], "live: the key is sent")
            try MediaUITests.inline([center.worker]) {
                center.poll()
                let web = WebNowPlayingMeasure(name: "WNP2", section: section("WNP2", [("PlayerType", "Title")]),
                                               skin: skin, type: "webnowplaying")
                web.center = center
                web.readOptions()
                _ = web.computeValue()
                web.execute(command: "Next")
            }
            t.equal(backend.performed.count, 1, "live: the player gets the command")
            t.equal(recording.records.count, 13, "nothing more recorded")
            skin.close()
        }
    }
}
