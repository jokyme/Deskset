#if DEBUG
import AppKit
import Darwin
@testable import DesksetCore

enum LegacyRenderWebFixtureSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: legacy renderer: web fixtures match exact requests and stay inside their directory") {
            let root = t.temporaryDirectory("legacy-web-fixtures")
            let outside = t.temporaryDirectory("legacy-web-outside").appendingPathComponent("outside.xml")
            let page = root.appendingPathComponent("page.xml")
            let other = root.appendingPathComponent("other.xml")
            let manifest = root.appendingPathComponent("responses.json")
            let subject = "https://fixture.invalid/feed?edition=1"
            let payload = Data("<feed><entry>Offline news</entry></feed>".utf8)
            try payload.write(to: page)
            try Data("different response".utf8).write(to: other)
            try payload.write(to: outside)
            func write(_ object: JSONValue) throws {
                try Data(object.description.utf8).write(to: manifest)
            }
            func mapping(_ value: JSONValue, kind: String = "webParserPage", url: String? = nil) -> JSONValue {
                .object([kind: .object([url ?? subject: value])])
            }
            func request(_ url: String = "https://fixture.invalid/feed?edition=1",
                         kind: BackgroundWorkKind = .webParserPage) -> BackgroundWorkRequest {
                BackgroundWorkRequest(kind: kind, subject: url, config: "Web fixture")
            }
            func rejects(_ object: JSONValue, _ reason: String) throws {
                try write(object)
                do {
                    _ = try LegacyRenderWebFixtures(manifest: manifest)
                    t.check(false, reason)
                } catch { t.check(true, reason) }
            }

            try write(mapping(.string("page.xml")))
            let fixtures = try LegacyRenderWebFixtures(manifest: manifest)
            t.equal(try fixtures.response(for: request()), payload)
            t.equal(try fixtures.response(for: request("https://fixture.invalid/feed?edition=2")), nil,
                    "a query change needs its own response")
            t.equal(try fixtures.response(for: request("http://fixture.invalid/feed?edition=1")), nil,
                    "the scheme is part of the exact request")
            t.equal(try fixtures.response(for: request(kind: .webParserDownload)), nil,
                    "a page response does not fake a download")
            try write(.object([
                "webParserPage": .object([subject: .string("page.xml")]),
                "webParserDownload": .object([subject: .string("other.xml")]),
            ]))
            let separate = try LegacyRenderWebFixtures(manifest: manifest)
            t.equal(try separate.response(for: request()), payload)
            t.equal(try separate.response(for: request(kind: .webParserDownload)), Data("different response".utf8))

            try rejects(mapping(.string(outside.path)), "absolute fixture paths are rejected")
            try rejects(mapping(.string("../" + outside.deletingLastPathComponent().lastPathComponent + "/outside.xml")),
                        "parent traversal is rejected")
            let linked = root.appendingPathComponent("linked.xml")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
            try rejects(mapping(.string("linked.xml")), "symlinks outside the fixture folder are rejected")
            try rejects(mapping(.string("page.xml"), kind: "ping"), "other services cannot be declared as web responses")
            try rejects(mapping(.string("page.xml"), url: "YourFeedHere"), "an unconfigured address is not a response")
            try rejects(mapping(.string("page.xml"), url: "file:///page.xml"), "local files keep their existing input path")
            try rejects(mapping(.number(1)), "a response must name a file")
            try rejects(.array([]), "a manifest must be an object")

            func invalidResponse(_ reason: String) {
                do {
                    _ = try fixtures.response(for: request())
                    t.check(false, reason)
                } catch { t.check(true, reason) }
            }
            try Data().write(to: page)
            invalidResponse("an empty file cannot claim input coverage")
            try FileManager.default.removeItem(at: page)
            invalidResponse("a missing file cannot claim input coverage")
            t.equal(mkfifo(page.path, 0o600), 0)
            invalidResponse("a pipe is rejected before opening it")
            try FileManager.default.removeItem(at: page)
            t.check(FileManager.default.createFile(atPath: page.path, contents: nil))
            let sparse = try FileHandle(forWritingTo: page)
            try sparse.truncate(atOffset: 16 * 1_048_576 + 1)
            try sparse.close()
            invalidResponse("an oversized page is rejected before reading it")
            try FileManager.default.removeItem(at: page)
            try FileManager.default.createSymbolicLink(at: page, withDestinationURL: outside)
            invalidResponse("a file replaced by an outside symlink is rejected when requested")
        }

        t.suite("Runtime: legacy renderer: mapped web inputs reach measures and broken mappings stay unverified") {
            guard let source = Paths.repositoryFolder("TestSkins") else { return }
            let skins = t.temporaryDirectory("legacy-web-render").appendingPathComponent("TestSkins")
            try FileManager.default.copyItem(at: source, to: skins)
            let folder = skins.appendingPathComponent("Runtime/WebFixtures")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let page = folder.appendingPathComponent("feed.xml")
            let artwork = folder.appendingPathComponent("artwork.png")
            let manifest = folder.appendingPathComponent("responses.json")
            let file = folder.appendingPathComponent("Web.ini")
            let data = skins.appendingPathComponent("Runtime/Data/mac.json")
            let cover = try Data(contentsOf: skins.appendingPathComponent("Runtime/Data/cover.png"))
            try cover.write(to: artwork)
            try "<feed><title>Offline headline</title></feed>".write(to: page, atomically: true, encoding: .utf8)
            let mappings = JSONValue.object([
                "webParserPage": .object(["https://fixture.invalid/feed.xml": .string("feed.xml")]),
                "webParserDownload": .object(["https://fixture.invalid/artwork.png": .string("artwork.png")]),
            ])
            try Data(mappings.description.utf8).write(to: manifest)
            let fixtures = try LegacyRenderWebFixtures(manifest: manifest)
            try """
            [Rainmeter]
            Update=1000
            [Page]
            Measure=WebParser
            URL=https://fixture.invalid/feed.xml
            RegExp=(?s)<title>(.*?)</title>
            StringIndex=1
            [Picture]
            Measure=WebParser
            URL=https://fixture.invalid/artwork.png
            Download=1
            DownloadFile=#CURRENTPATH#download.png
            [Title]
            Meter=String
            MeasureName=Page
            FontSize=12
            W=200
            H=30
            [Art]
            Meter=Image
            MeasureName=Picture
            Y=32
            W=48
            H=48
            """.write(to: file, atomically: true, encoding: .utf8)
            let checked = try LegacyRenderSelfTests.withInputs(file, skinsDir: skins.path, data: data,
                                                               webFixtures: fixtures) { skin, recording, virtual in
                t.equal(skin.measure(named: "Page")?.stringValue, "Offline headline", "the parser read the local XML")
                let path = skin.measure(named: "Picture")?.stringValue ?? ""
                t.equal(try Data(contentsOf: URL(fileURLWithPath: path)), cover, "the download contains the fixture bytes")
                t.check(recording.files.contains(path), "the download stays in the recording's copy")
                t.check(Images.cgImage(atPath: path) != nil, "the download is a real decodable image")
                for kind in [BackgroundWorkKind.webParserPage, .webParserDownload] {
                    t.check(virtual.background.reports.contains { $0.kind == kind && $0.faked })
                }
                for scale in [1.0, 2.0] {
                    let pictures = LegacyRenderSelfTests.pngs(skin, scale: scale, colorSpace: .srgb)
                    t.check(pictures != nil && pictures?.current == pictures?.legacy,
                            "the parsed text and downloaded image draw the same at \(scale)x")
                }
            }
            t.equal(checked.missing, [], "the declared responses cover both inputs")
            t.check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("download.png").path),
                    "the original skin tree received no download")

            try Data().write(to: page)
            let broken = try LegacyRenderSelfTests.withInputs(file, skinsDir: skins.path, data: data,
                                                              webFixtures: fixtures) { skin, _, _ in
                t.equal(skin.measure(named: "Page")?.stringValue, "", "an invalid mapping is a failed request")
            }
            t.check(broken.missing.contains { $0.contains("https://fixture.invalid/feed.xml") && $0.contains("mapped fixture") },
                    "a scripted failure still prevents complete input coverage")
        }
    }
}
#endif
