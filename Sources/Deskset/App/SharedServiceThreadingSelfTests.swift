import AppKit
import CoreText
import DesksetCore
import ImageIO

/// `Images` and `Fonts` are shared by every skin, and skins are to measure and draw on threads of their own
/// (docs/skin-threading.md §4.4, phase 1). These suites use them from several dedicated threads at once, released
/// together:
/// - a file several threads want at once is decoded once, and a derived image is made once;
/// - files replaced and purged under the readers never hand out an image of the wrong version;
/// - fonts resolve the same on every thread; a font folder is registered once, and every thread that asked for it
///   finds its fonts; rescans under running layouts keep the fonts consistent;
/// - a registration is announced on the main thread, a turn later, and running skins measure their text again.
///
/// The threads never call the runner (it is not thread-safe): they report into `Collected`, and the suite checks that
/// afterwards. Run them under `scripts/check-main-thread.sh "skin threading"` too: `Fonts` keeps a few AppKit lookups.
enum SharedServiceThreadingSelfTests {
    static func run(_ t: AppTestRunner) {
        imageTests(t)
        fontTests(t)
    }

    // MARK: Images

    static func imageTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: threads that want one file at once decode it once") {
            let folder = t.temporaryDirectory("images-threads")
            let file = folder.appendingPathComponent("photo.png").path
            try writePNG(to: file, width: 600, height: 400)
            let threads = 4
            let decodes = Collected<Bool>()
            // The first thread's decode is held up until the others wait for it (or a minute has passed).
            Images.willDecode = { path in
                guard path == file else { return }
                decodes.add(waitOnThread { Images.waitingCount >= threads - 1 })
            }
            t.atSuiteEnd { Images.willDecode = nil }
            let images = Collected<CGImage?>()
            t.check(onThreads(threads) { _ in images.add(Images.cgImage(atPath: file)) }, "the threads finish")
            Images.willDecode = nil
            t.equal(decodes.all, [true], "decoded once, while the other threads waited for it")
            let all = images.all
            t.equal(all.count, threads)
            t.check(all.allSatisfy { $0 != nil && $0 === all.first ?? nil }, "every thread got the same image")
            t.equal(all.first??.width, 600)

            // A derived image is made once too, whoever asks.
            guard let entry = Images.entry(atPath: file) else { return t.check(false, "decoded") }
            let key = Images.DerivedKey(path: file, generation: entry.generation,
                                        recipe: .region(.oriented, x: 10, y: 20, width: 30, height: 40))
            let makes = Collected<Bool>()
            let derived = Collected<CGImage?>()
            t.check(onThreads(threads) { _ in
                derived.add(Images.derived(key) {
                    makes.add(waitOnThread { Images.waitingCount >= threads - 1 })
                    return entry.image.cropping(to: CGRect(x: 10, y: 20, width: 30, height: 40))
                })
            }, "the threads finish")
            t.equal(makes.all, [true], "made once, while the other threads waited for it")
            let crops = derived.all
            t.check(crops.count == threads && crops.allSatisfy { $0 != nil && $0 === crops.first ?? nil },
                    "every thread got the same image")
            t.equal(crops.first??.width, 30)

            // A Refresh All while a file is being decoded: the thread gets its image, the cache keeps nothing of it.
            let later = folder.appendingPathComponent("later.png").path
            try writePNG(to: later, width: 20, height: 10)
            let held = Collected<Bool>()
            Images.willDecode = { path in
                guard path == later else { return }
                held.add(true)
                _ = waitOnThread { held.count > 1 }
            }
            let decoded = Collected<CGImage?>()
            let finished = Collected<Bool>()
            let thread = Thread {
                decoded.add(Images.cgImage(atPath: later))
                finished.add(true)
            }
            thread.stackSize = 8 << 20
            thread.start()
            t.check(AppSelfTest.spin(timeout: 60) { held.count == 1 }, "the decode started")
            Images.purge()
            held.add(true)
            t.check(AppSelfTest.spin(timeout: 60) { finished.count == 1 }, "and finished")
            t.equal(decoded.all.first??.width, 20, "the thread got its image")
            Images.willDecode = { path in if path == later { held.add(true) } }
            t.equal(Images.cgImage(atPath: later)?.width, 20)
            t.equal(held.count, 3, "decoded again: what was decoded across the purge was not kept")
            t.equal(Images.cgImage(atPath: later)?.width, 20)
            t.equal(held.count, 3, "and kept this time")
            Images.willDecode = nil
        }

        t.suite("App: skin threading: images replaced and purged while threads draw them") {
            let folder = t.temporaryDirectory("images-churn")
            // A file an editor keeps saving (a new inode each time), in two versions told apart by their size, and
            // one that stays: transparent on its left half, opaque on its right half.
            let changing = folder.appendingPathComponent("changing.png").path
            let versions = [(24, 12), (36, 18)]
            try writePNG(to: changing, width: versions[0].0, height: versions[0].1)
            let steady = folder.appendingPathComponent("steady.png").path
            try writePNG(to: steady, width: 20, height: 20, clearLeftHalf: true)
            let readers = 4, rounds = 40
            let problems = Collected<String>()
            func isVersion(_ width: Int, _ height: Int) -> Bool {
                versions.contains { $0.0 == width && $0.1 == height }
            }
            let finished = onThreads(readers + 1) { i in
                guard i < readers else {
                    for round in 1...rounds {
                        let (w, h) = versions[round % 2]
                        do {
                            try writePNG(to: changing, width: w, height: h, replacing: true)
                        } catch {
                            problems.add("write: \(error)")
                        }
                        if round % 8 == 0 { Images.purge() }
                    }
                    return
                }
                guard let ctx = Images.bitmapContext(width: 64, height: 64) else { return problems.add("context") }
                var options = ImageOptions()
                options.crop = ImageOptions.Crop(x: 2, y: 2, width: 8, height: 6)
                options.tint = RGBA(r: 255, g: 0, b: 0, a: 255)
                options.rotate = 90
                for _ in 0..<150 {
                    if let size = Images.size(atPath: changing), !isVersion(Int(size.width), Int(size.height)) {
                        problems.add("size \(size)")
                    }
                    if let image = Images.cgImage(atPath: changing, exifOriented: true),
                       !isVersion(image.width, image.height) {
                        problems.add("image \(image.width)×\(image.height)")
                    }
                    if let prepared = PreparedImage(path: changing, options: options) {
                        if prepared.image.width != 8 || prepared.image.height != 6 {
                            problems.add("prepared \(prepared.image.width)×\(prepared.image.height)")
                        }
                        if let flat = prepared.flattened(), flat.width != 6 || flat.height != 8 {
                            problems.add("flattened \(flat.width)×\(flat.height)")
                        }
                        if let part = prepared.region(SkinRect(x: 0, y: 0, width: 4, height: 3)),
                           part.width != 4 || part.height != 3 {
                            problems.add("region \(part.width)×\(part.height)")
                        }
                    }
                    SkinRenderer.drawImageFile(atPath: changing, options: options, in: CGRect(x: 0, y: 0, width: 32,
                                                                                               height: 32), ctx)
                    let left = Images.pixelAlpha(atPath: steady, x: 2, y: 5, oriented: false)
                    let right = Images.pixelAlpha(atPath: steady, x: 15, y: 5, oriented: false)
                    if left != 0 || right != 255 {
                        problems.add("alpha \(String(describing: left)) \(String(describing: right))")
                    }
                }
            }
            t.check(finished, "the threads finish")
            t.equal(problems.all, [], "every image handed out is one of the file's versions")
            let last = versions[rounds % 2]
            t.equal(Images.size(atPath: changing).map { [$0.width, $0.height] }, [Double(last.0), Double(last.1)],
                    "the cache holds the last version")
        }
    }

    // MARK: Fonts

    static func fontTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: fonts resolve the same on every thread") {
            var requests: [Fonts.Request] = []
            let faces = ["Arial", "Segoe UI", "Segoe UI Semibold", "Consolas", "Arial-BoldMT",
                         "Helvetica Neue Light Italic", "No Such Font", "Marlett", "Microsoft YaHei", "Times New Roman"]
            for face in faces {
                for weight in [nil, 300, 700] as [Int?] {
                    for italic in [false, true] {
                        requests.append(Fonts.Request(face: face, size: 16, weight: weight, italic: italic))
                    }
                }
            }
            requests.append(Fonts.Request(face: "Segoe UI", size: 20, stretch: 3))
            requests.append(Fonts.Request(face: "Arial", size: 14, oblique: true))
            requests.append(Fonts.Request(face: "Arial", size: 14, features: [Fonts.Feature(tag: "liga", value: 0)]))
            let texts = ["Hello there", "Wrapped text that is long enough to wrap", "12:34:56"]
            var styles: [TextStyle] = []
            for face in ["Arial", "Segoe UI", "Consolas", "No Such Font"] {
                var style = TextStyle()
                style.fontFace = face
                style.fontSize = 11
                styles.append(style)
            }
            func sizes(_ cache: TextLayoutCache) -> [String] {
                styles.flatMap { style in
                    texts.map { text in
                        let size = cache.layout(text, style: style, wrapWidth: 80, cycle: 0).size
                        return "\(style.fontFace) \(text): \(size.width)×\(size.height)"
                    }
                }
            }
            let expected = requests.map { describe(Fonts.resolve($0)) }
            let expectedSizes = sizes(TextLayoutCache())

            // New fonts clear what resolution kept, so the threads resolve every request afresh, at the same time.
            let root = t.temporaryDirectory("fonts-resolve")
            let folder = root.appendingPathComponent("@Resources/Fonts")
            let added = AppSelfTest.makeTestFont(family: "DesksetTstR", at: folder.appendingPathComponent("R.ttf"))
            if added { t.check(Fonts.rescanFolder(folder.path), "the fonts changed") }
            let threads = 6
            let results = Collected<(Int, [String], [String])>()
            t.check(onThreads(threads) { i in
                // Each thread in its own order.
                let order = Array(requests.indices.dropFirst(i * 7 % requests.count))
                    + Array(requests.indices.prefix(i * 7 % requests.count))
                var described = Array(repeating: "", count: requests.count)
                for index in order { described[index] = describe(Fonts.resolve(requests[index])) }
                results.add((i, described, sizes(TextLayoutCache())))
            }, "the threads finish")
            let all = results.all
            t.equal(all.count, threads)
            for (i, described, layoutSizes) in all {
                t.equal(described, expected, "thread \(i): the fonts resolved on the main thread")
                t.equal(layoutSizes, expectedSizes, "thread \(i): the text measured on the main thread")
            }
            if added {
                try FileManager.default.removeItem(at: root.appendingPathComponent("@Resources"))
                t.check(Fonts.rescanFolder(folder.path))
            }
        }

        t.suite("App: skin threading: a font folder is registered once, and every thread that asked finds its fonts") {
            let root = t.temporaryDirectory("fonts-once")
            let folder = root.appendingPathComponent("@Resources/Fonts")
            let file = folder.appendingPathComponent("K.ttf")
            guard AppSelfTest.makeTestFont(family: "DesksetTstK", at: file) else {
                print("    (skipped: Courier New not found)")
                return
            }
            let before = Fonts.generation
            let threads = 6
            let families = Collected<String>()
            t.check(onThreads(threads) { _ in
                Fonts.registerFolder(folder.path)
                families.add(CTFontCopyFamilyName(Fonts.resolve(Fonts.Request(face: "DesksetTstK", size: 12)).font)
                             as String)
            }, "the threads finish")
            t.equal(families.all, Array(repeating: "DesksetTstK", count: threads),
                    "every thread came back with the folder's fonts registered")
            t.equal(Fonts.generation, before + 1, "registered once")
            t.check(Fonts.registeredCopy(ofFile: file.path) != nil)
            try FileManager.default.removeItem(at: root.appendingPathComponent("@Resources"))
            t.check(Fonts.rescanFolder(folder.path))
            t.check(!AppSelfTest.familyAvailable("DesksetTstK"))
        }

        t.suite("App: skin threading: fonts registered off the main thread are announced there; skins measure again") {
            // Announcements of earlier suites' registrations come first.
            t.check(drainMainQueue())
            let announcements = Collected<Bool>()
            let token = NotificationCenter.default.addObserver(forName: Fonts.didChangeNotification, object: nil,
                                                               queue: nil) { _ in
                announcements.add(Thread.isMainThread)
            }
            defer { NotificationCenter.default.removeObserver(token) }
            let root = t.temporaryDirectory("fonts-announce")
            let folderA = root.appendingPathComponent("A/@Resources/Fonts")
            let folderB = root.appendingPathComponent("B/@Resources/Fonts")
            guard AppSelfTest.makeTestFont(family: "DesksetTstN", at: folderA.appendingPathComponent("N.ttf")),
                  AppSelfTest.makeTestFont(family: "DesksetTstP", at: folderB.appendingPathComponent("P.ttf")) else {
                print("    (skipped: Courier New not found)")
                return
            }
            defer {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("A"))
                try? FileManager.default.removeItem(at: root.appendingPathComponent("B"))
                Fonts.rescanFolders([folderA.path, folderB.path])
            }
            // Also on the main thread, the announcement comes later, not in the middle of the registration.
            t.check(Fonts.rescanFolder(folderA.path))
            t.equal(announcements.count, 0, "not announced while registering")
            t.check(AppSelfTest.spin(timeout: 60) { announcements.count == 1 }, "announced on a later turn")

            // A running skin whose font is not there yet measures its text again once another thread registered it,
            // without anyone telling the app.
            guard let app = try AppSelfTest.makeApp(t) else { return }
            app.observeFonts()
            t.atSuiteEnd { app.stopAllForTermination() }
            let dir = app.skinsDirectory.appendingPathComponent("FontLater/Widget", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ("[Rainmeter]\nUpdate=1000\n[Text]\nMeter=String\nFontFace=DesksetTstP\nFontSize=20\n"
                 + "Text=iiiiiiiiiiii\n").write(to: dir.appendingPathComponent("Widget.ini"), atomically: true,
                                                 encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "FontLater\\Widget", file: "Widget.ini"),
                  let meter = c.skin.meter(named: "Text") else {
                return t.check(false, "skin loaded")
            }
            let fallbackWidth = meter.frame.width
            t.check(onThreads(1) { _ in Fonts.registerFolder(folderB.path) }, "the thread finishes")
            t.check(AppSelfTest.spin(timeout: 60) { meter.frame.width > fallbackWidth * 1.5 },
                    "monospaced i's are wider than the fallback's: \(fallbackWidth) → \(meter.frame.width)")
            t.check(c.skin.width >= meter.frame.width, "the window size follows")
            t.check(announcements.count == 2 && announcements.all.allSatisfy { $0 }, "announced on the main thread")
        }

        t.suite("App: skin threading: fonts rescanned while threads lay out text") {
            let root = t.temporaryDirectory("fonts-churn")
            let folder = root.appendingPathComponent("@Resources/Fonts")
            let file = folder.appendingPathComponent("Q.ttf")
            guard AppSelfTest.makeTestFont(family: "DesksetTstQ", at: file) else {
                print("    (skipped: Courier New not found)")
                return
            }
            let data = try Data(contentsOf: file)
            let fallback = CTFontCopyFamilyName(Fonts.resolve(Fonts.Request(face: "No Such Font", size: 14)).font)
                as String
            var style = TextStyle()
            style.fontFace = "DesksetTstQ"
            style.fontSize = 14
            style.fontFolder = folder.path
            let readers = 4, rounds = 15
            let problems = Collected<String>()
            let finished = onThreads(readers + 1) { i in
                guard i < readers else {
                    // A skin author removing the font and putting it back, and a refresh reading the folder each time.
                    for _ in 0..<rounds {
                        try? FileManager.default.removeItem(at: file)
                        Fonts.rescanFolder(folder.path)
                        do {
                            try data.write(to: file)
                        } catch {
                            problems.add("write: \(error)")
                        }
                        Fonts.rescanFolder(folder.path)
                    }
                    return
                }
                let cache = TextLayoutCache()
                var seen = 0
                for n in 0..<200 {
                    let generation = Fonts.generation
                    if generation < seen { problems.add("the generation went back: \(seen) → \(generation)") }
                    seen = generation
                    let layout = cache.layout("Line \(n % 7)", style: style, wrapWidth: n % 2 == 0 ? nil : 60, cycle: n)
                    if layout.size.width <= 0 { problems.add("an empty layout") }
                    let family = CTFontCopyFamilyName(Fonts.resolve(Fonts.request(for: style)).font) as String
                    if family != "DesksetTstQ" && family != fallback { problems.add("family \(family)") }
                }
            }
            t.check(finished, "the threads finish")
            t.equal(problems.all, [])
            t.check(AppSelfTest.familyAvailable("DesksetTstQ"), "the font is there at the end")
            t.equal(CTFontCopyFamilyName(Fonts.resolve(Fonts.request(for: style)).font) as String, "DesksetTstQ",
                    "and resolved")
            try FileManager.default.removeItem(at: root.appendingPathComponent("@Resources"))
            t.check(Fonts.rescanFolder(folder.path))
            t.check(!AppSelfTest.familyAvailable("DesksetTstQ"))
        }
    }

    // MARK: Helpers

    /// Runs `body(i)` for every `i` in `0..<count`, each on a thread of its own with the 8 MB stack a skin thread gets
    /// (docs/skin-threading.md §5.3), all released together. The main run loop keeps turning meanwhile (fonts are
    /// announced there). False when they have not all finished within `timeout` seconds.
    static func onThreads(_ count: Int, timeout: TimeInterval = 60, _ body: @escaping (Int) -> Void) -> Bool {
        let gate = DispatchSemaphore(value: 0)
        let finished = Collected<Int>()
        for i in 0..<count {
            let thread = Thread {
                gate.wait()
                body(i)
                finished.add(i)
            }
            thread.name = "Deskset self-test thread \(i)"
            thread.stackSize = 8 << 20
            thread.start()
        }
        for _ in 0..<count { gate.signal() }
        return AppSelfTest.spin(timeout: timeout) { finished.count == count }
    }

    /// Runs the main queue until everything queued on it so far has run; false after a minute.
    static func drainMainQueue() -> Bool {
        let drained = Collected<Bool>()
        DispatchQueue.main.async { drained.add(true) }
        return AppSelfTest.spin(timeout: 60) { drained.count == 1 }
    }

    /// Waits on a worker thread until `condition` holds; false after `timeout` seconds.
    static func waitOnThread(timeout: TimeInterval = 60, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            usleep(1000)
        }
        return true
    }

    /// What worker threads report, for the test thread to check afterwards.
    final class Collected<T> {
        private let lock = NSLock()
        private var items: [T] = []

        func add(_ item: T) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var all: [T] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return items.count
        }
    }

    /// A resolved font in words: which font at which size, and what the renderer does on top of it.
    private static func describe(_ resolved: Fonts.Resolved) -> String {
        let name = CTFontCopyPostScriptName(resolved.font) as String
        let metrics = resolved.lineMetrics.map { "\($0.ascent)/\($0.descent)/\($0.leading)" } ?? "-"
        return "\(name) \(CTFontGetSize(resolved.font)) bold \(resolved.syntheticBold) slant \(resolved.slant) "
            + "map \(resolved.characterMap?.count ?? -1) metrics \(metrics)"
    }

    /// Writes a `width` × `height` PNG, opaque blue, or transparent on its left half. `replacing` writes it next to
    /// the file and moves it over, as an editor saving it would: readers see the old file or the new one, never half of
    /// it.
    static func writePNG(to path: String, width: Int, height: Int, clearLeftHalf: Bool = false,
                         replacing: Bool = false) throws {
        guard let ctx = Images.bitmapContext(width: width, height: height) else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1))
        let left = clearLeftHalf ? width / 2 : 0
        ctx.fill(CGRect(x: left, y: 0, width: width - left, height: height))
        let target = URL(fileURLWithPath: path)
        let url = replacing ? target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
            : target
        guard let image = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        if replacing, rename(url.path, path) != 0 { throw CocoaError(.fileWriteUnknown) }
    }
}
