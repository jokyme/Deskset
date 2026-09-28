import AppKit
import DesksetCore

/// Legacy ANSI skins are read in the code page of the user's language, as Rainmeter reads them in the Windows locale's
/// (old Chinese skins are often GBK): main.swift sets `TextDecoding.ansiCodePage` first thing, except under
/// `--self-test`. These suites set other code pages explicitly and put the old one back (the skins of earlier suites,
/// still running on their threads, read no ANSI files).
enum ANSICodePageSelfTests {
    /// `TextDecoding.ansiCodePage` when `AppSelfTest.run` started, before any suite could change it.
    static var codePageAtStart = 0

    static func run(_ t: AppTestRunner) {
        choiceTests(t)
        skinTests(t)
        renderTests(t)
    }

    /// Makes `folder/name` hold `text` in `encoding`.
    private static func write(_ text: String, _ encoding: TextFileEncoding, to folder: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = TextDecoding.encode(text, as: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: folder.appendingPathComponent(name))
    }

    private static func skin(text: String, face: String) -> String {
        "[Rainmeter]\r\nUpdate=1000\r\nBackgroundMode=2\r\nSolidColor=255,255,255\r\n[Variables]\r\nNote=\r\n"
            + "[Label]\r\nMeter=String\r\nText=\(text)\r\nFontFace=\(face)\r\nFontSize=20\r\nFontColor=0,0,0\r\n"
            + "AntiAlias=1\r\n"
    }

    static let gbkSkin = skin(text: "中文皮肤 GBK 编码", face: "微软雅黑")
    static let big5Skin = skin(text: "中文皮膚 Big5 編碼", face: "微軟正黑體")

    static func choiceTests(_ t: AppTestRunner) {
        t.suite("App: ANSI code page: the user's language, except in the self-tests") {
            func codePage(_ args: [String], _ languages: [String]) -> Int? {
                CommandLineTools.ansiCodePage(for: ["/Applications/Deskset.app/Contents/MacOS/Deskset"] + args,
                                              preferredLanguages: languages)
            }
            // The menu bar app, with the Skin Studio and the installer, as Finder starts it.
            t.equal(codePage([], ["zh-Hans-SG"]), 936, "Simplified Chinese: GBK")
            t.equal(codePage(["-psn_0_1234567"], ["zh-Hant-TW", "en"]), 950, "Traditional Chinese: Big5")
            t.equal(codePage([], ["en-US", "zh-Hans-CN"]), 1252, "the first language decides")
            // Every mode that loads skins.
            t.equal(codePage(["--render", "a.ini", "--out", "a.png"], ["zh-Hans-CN"]), 936)
            t.equal(codePage(["--verify-drawing-cache", "Skins"], ["ja-JP"]), 932)
            t.equal(codePage(["--snapshot-ui", "manage", "--skins-dir", "/tmp/S"], ["ru"]), 1251)
            // The self-tests read files the same way on English CI runners and a Chinese Mac.
            t.equal(codePage(["--self-test"], ["zh-Hans-SG"]), nil)
            t.equal(codePage(["-AppleShowScrollBars", "Always", "--self-test", "App: Audio"], ["zh-Hant-TW"]), nil)
            t.equal(codePageAtStart, 1252,
                    "this run started with the core's 1252 (first language: \(Locale.preferredLanguages.first ?? "none"))")

            let saved = TextDecoding.ansiCodePage
            defer { TextDecoding.ansiCodePage = saved }
            CommandLineTools.useANSICodePage(for: ["Deskset"], preferredLanguages: ["zh-Hant-HK"])
            t.equal(TextDecoding.ansiCodePage, 950)
            CommandLineTools.useANSICodePage(for: ["Deskset", "--self-test"], preferredLanguages: ["ja"])
            t.equal(TextDecoding.ansiCodePage, 950, "left alone under --self-test")
        }
    }

    static func skinTests(_ t: AppTestRunner) {
        t.suite("App: ANSI code page: GBK and Big5 skins read and write in the user's code page") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let saved = TextDecoding.ansiCodePage
            defer {
                TextDecoding.ansiCodePage = saved
                app.stopAllForTermination()
            }
            let folder = app.skinsDirectory.appendingPathComponent("Legacy", isDirectory: true)
            try write(gbkSkin, .windowsCodePage(936), to: folder, "GBK.ini")
            try write(big5Skin, .windowsCodePage(950), to: folder, "Big5.ini")
            app.rescanLibrary()
            func label(_ file: String) -> (text: String, family: String)? {
                guard let c = app.activate(config: "Legacy", file: file),
                      let meter = c.skin.meter(named: "Label") as? StringMeter else { return nil }
                return (meter.text, Fonts.font(for: meter.style).familyName ?? "")
            }

            // Windows-1252 (an English Mac): the GBK bytes read as Latin letters, drawn in a fallback font.
            TextDecoding.ansiCodePage = 1252
            let western = label("GBK.ini")
            t.check(western?.text.hasPrefix("ÖÐÎÄ") == true, "GBK bytes read as 1252: \(western?.text ?? "not loaded")")

            CommandLineTools.useANSICodePage(for: ["Deskset"], preferredLanguages: ["zh-Hans-SG"])
            let hans = label("GBK.ini")
            t.equal(hans?.text, "中文皮肤 GBK 编码", "GBK under 936")
            t.equal(hans?.family, "PingFang SC", "微软雅黑 is Microsoft YaHei")

            CommandLineTools.useANSICodePage(for: ["Deskset"], preferredLanguages: ["zh-Hant-TW"])
            let hant = label("Big5.ini")
            t.equal(hant?.text, "中文皮膚 Big5 編碼", "Big5 under 950")
            t.equal(hant?.family, "PingFang TC", "微軟正黑體 is Microsoft JhengHei")

            // Writing a value back keeps a GBK file GBK (!WriteKeyValue; the Studio and the installer write through
            // the same TextDecoding).
            CommandLineTools.useANSICodePage(for: ["Deskset"], preferredLanguages: ["zh-Hans-CN"])
            guard let c = app.activate(config: "Legacy", file: "GBK.ini") else {
                return t.check(false, "GBK.ini loads")
            }
            c.skin.execute("[!WriteKeyValue Variables Note 你好]", from: nil)
            let expected = gbkSkin.replacingOccurrences(of: "Note=\r\n", with: "Note=你好\r\n")
            t.equal(try Data(contentsOf: folder.appendingPathComponent("GBK.ini")),
                    TextDecoding.encode(expected, as: .windowsCodePage(936)), "still GBK, nothing else changed")
        }
    }

    /// `Deskset --render` in a child process with its languages set by `-AppleLanguages`: what main.swift does before
    /// any mode runs. A GBK or Big5 skin draws the same picture as its UTF-16 copy.
    static func renderTests(_ t: AppTestRunner) {
        t.suite("App: ANSI code page: --render follows -AppleLanguages") {
            guard let binary = Bundle.main.executableURL else { return t.check(false, "the app binary") }
            let root = t.temporaryDirectory("ansi-render")
            let skins = root.appendingPathComponent("Skins", isDirectory: true)
            let cases: [(config: String, text: String, encoding: TextFileEncoding)] = [
                ("GBK", gbkSkin, .windowsCodePage(936)), ("GBKUnicode", gbkSkin, .utf16LittleEndian(bom: true)),
                ("Big5", big5Skin, .windowsCodePage(950)), ("Big5Unicode", big5Skin, .utf16LittleEndian(bom: true)),
            ]
            for c in cases {
                try write(c.text, c.encoding, to: skins.appendingPathComponent(c.config), "Skin.ini")
            }
            func render(_ config: String, languages: String) throws -> Data? {
                let out = root.appendingPathComponent("\(config)-\(languages.filter(\.isLetter)).png")
                let process = Process()
                process.executableURL = binary
                process.arguments = ["-AppleLanguages", languages, "--render",
                                     skins.appendingPathComponent(config).appendingPathComponent("Skin.ini").path,
                                     "--skins-dir", skins.path, "--out", out.path, "--updates", "1", "--interval", "0",
                                     "--scale", "1"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                t.equal(process.terminationStatus, 0, "--render \(config) with \(languages)")
                return try? Data(contentsOf: out)
            }
            let gbkUnicode = try render("GBKUnicode", languages: "(en)")
            t.check(gbkUnicode != nil, "the UTF-16 skin renders")
            t.equal(try render("GBK", languages: "(zh-Hans-SG)"), gbkUnicode, "GBK under Simplified Chinese")
            t.check(try render("GBK", languages: "(en-US)") != gbkUnicode, "GBK under English is read as 1252")
            let big5Unicode = try render("Big5Unicode", languages: "(en)")
            t.equal(try render("Big5", languages: "(zh-Hant-TW)"), big5Unicode, "Big5 under Traditional Chinese")
        }
    }
}
