import DesksetCore
import Foundation

/// Favorites use temporary state files; no installed skins or user preferences are changed.
enum FavoritesStateSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Favorites: older state and unrelated settings survive saves") {
            let file = t.temporaryDirectory("favorites-old-state").appendingPathComponent("state.json")
            try #"{"skins":{"Suite\\Clock":{"file":"Clock.ini","active":false,"futureSkin":3}},"futureApp":[1,2]}"#
                .write(to: file, atomically: true, encoding: .utf8)
            let state = AppState(fileURL: file)
            t.equal(state.favorites, [])
            t.check(!state.isFavorite(config: "Suite\\Clock", file: "Clock.ini"))
            state.setFavorite(config: "Suite\\Clock", file: "Clock.ini", favorite: true)
            state.saveNow()
            let reopened = AppState(fileURL: file)
            t.check(reopened.isFavorite(config: "Suite\\Clock", file: "Clock.ini"))
            t.equal(reopened.skin("Suite\\Clock")?.active, false)
            t.equal(reopened.skin("Suite\\Clock")?.unknownKeys["futureSkin"], .number(3))
            t.equal(reopened.data.unknownKeys["futureApp"], .array([.number(1), .number(2)]))
            t.equal(reopened.data.unknownKeys["favorites"], nil)

            for value in ["null", "true", "3", "{}", #"[{"config":4,"file":"A.ini"}]"#] {
                let data = try JSONDecoder().decode(AppStateData.self, from: Data("{\"favorites\":\(value)}".utf8))
                t.equal(data.favorites, [], "malformed favorite values use an empty list")
            }
        }

        t.suite("App: Favorites: normalized paths and case-insensitive variant identities") {
            let file = t.temporaryDirectory("favorites-normalization").appendingPathComponent("state.json")
            try #"""
            {"favorites":[
              {"config":" Suite/Clock/ ","file":"A.INI"},
              {"config":"suite\\CLOCK","file":"a.ini"},
              {"config":"Suite\\Clock","file":"B.ini"},
              {"config":"..\\Outside","file":"A.ini"},
              {"config":"Suite\\Clock","file":"../A.ini"},
              {"config":"Suite\\Clock","file":"notes.txt"},
              {"config":"Suite\\\\Clock","file":"A.ini"},
              {"config":"","file":"A.ini"}
            ]}
            """#.write(to: file, atomically: true, encoding: .utf8)
            let state = AppState(fileURL: file)
            t.equal(state.favorites.count, 2)
            t.equal(state.favorites.first?.config, "Suite\\Clock")
            t.equal(state.favorites.first?.file, "A.INI", "the first stored spelling is retained")
            t.check(state.isFavorite(config: "suite/clock/", file: "a.ini"))
            t.check(state.isFavorite(config: "Suite\\Clock", file: "B.ini"))
            t.check(!state.isFavorite(config: "Suite\\Other", file: "A.ini"))
            t.check(!state.isFavorite(config: "Suite\\Clock", file: "C.ini"))
            state.setFavorite(config: "SUITE\\clock", file: "a.ini", favorite: true)
            t.equal(state.favorites.count, 2, "marking an existing item does not duplicate it")
            for (config, file) in [("../Outside", "A.ini"), ("Suite\\Clock", "../A.ini"),
                                   ("Suite\\Clock", "A.ini/B.ini"), ("Suite\\Clock", "notes.txt"),
                                   ("", "A.ini"), ("Suite\\Clock", "")] {
                state.setFavorite(config: config, file: file, favorite: true)
                t.check(!state.isFavorite(config: config, file: file))
            }
            t.equal(state.favorites.count, 2)
            state.setFavorite(config: "suite/clock", file: "a.ini", favorite: false)
            t.check(!state.isFavorite(config: "Suite\\Clock", file: "A.INI"))
            t.check(state.isFavorite(config: "Suite\\Clock", file: "B.ini"), "another variant keeps its shortcut")
            state.saveNow()
            let reopened = AppState(fileURL: file)
            t.equal(reopened.favorites, state.favorites)
        }

        t.suite("App: Favorites: unloading and restart retain local shortcuts without activating skins") {
            let file = t.temporaryDirectory("favorites-restart").appendingPathComponent("state.json")
            let state = AppState(fileURL: file)
            state.setFavorite(config: "Suite\\Clock", file: "A.ini", favorite: true)
            state.setFavorite(config: "Suite\\Clock", file: "B.ini", favorite: true)
            t.check(state.data.skins.isEmpty, "saving a shortcut never creates or activates a config")
            state.update("Suite\\Clock") { $0.file = "B.ini"; $0.active = true; $0.x = 42 }
            state.update("Suite\\Clock") { $0.active = false }
            state.saveNow()
            let reopened = AppState(fileURL: file)
            t.equal(reopened.skin("Suite\\Clock")?.active, false)
            t.equal(reopened.skin("Suite\\Clock")?.file, "B.ini")
            t.equal(reopened.skin("Suite\\Clock")?.x, 42)
            t.check(reopened.isFavorite(config: "Suite\\Clock", file: "A.ini"))
            t.check(reopened.isFavorite(config: "Suite\\Clock", file: "B.ini"))

            let library = [SkinConfig(name: "Suite\\Clock", directory: URL(fileURLWithPath: "/unused"),
                                      files: ["A.ini", "B.ini"])]
            let layout = LayoutStateCodec.capture(reopened.data, library: library, options: LayoutSaveOptions())
            t.equal(layout.section(named: "Favorites"), nil, "local shortcuts add no unconfirmed INI section")
            t.equal(layout.section(named: "Suite\\Clock")?["Favorite"], nil)
            reopened.replaceLayout(LayoutState(skins: [:], order: []))
            t.equal(reopened.favorites, state.favorites, "replacing local window settings does not clear shortcuts")
            reopened.saveNow()
            t.equal(AppState(fileURL: file).favorites, state.favorites)
        }

        t.suite("App: Favorites: selected skin snapshots do not defer favorite persistence") {
            let file = t.temporaryDirectory("favorites-selection").appendingPathComponent("state.json")
            let state = AppState(fileURL: file)
            state.update("Suite\\Clock") { $0.file = "Clock.ini"; $0.x = 10 }
            state.saveNow()
            state.beginSkinSelection("Suite\\Clock")
            state.update("Suite\\Clock") { $0.x = 200 }
            state.setFavorite(config: "Suite\\Clock", file: "Clock.ini", favorite: true)
            state.saveNow()
            let selected = AppState(fileURL: file)
            t.equal(selected.skin("Suite\\Clock")?.x, 10, "window settings still wait for deselection")
            t.check(selected.isFavorite(config: "Suite\\Clock", file: "Clock.ini"))
            state.setFavorite(config: "suite/clock", file: "clock.INI", favorite: false)
            state.saveNow()
            let removed = AppState(fileURL: file)
            t.equal(removed.favorites, [])
            t.equal(removed.skin("Suite\\Clock")?.x, 10)
            state.endSkinSelection("Suite\\Clock")
            state.saveNow()
            t.equal(AppState(fileURL: file).skin("Suite\\Clock")?.x, 200)
        }
    }
}
