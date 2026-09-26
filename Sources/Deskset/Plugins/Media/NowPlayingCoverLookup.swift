import Foundation

/// Cover art looked up online. Music's scripting interface is no reliable source for tracks streamed from Apple Music
/// (outside the user's files): their artwork arrives seconds late or not at all, and right after a track change
/// Music often still hands out the previous track's picture. So streamed tracks are looked up here first.
///
/// Uses Apple's public iTunes Search API (`https://itunes.apple.com/search`, no key needed): searches songs by artist
/// and title (albums by artist and album name when the title is missing) and takes the best match's `artworkUrl100`
/// at 600 × 600. The storefront of the user's region is searched first; when it has no match, one more storefront
/// (Taiwan for Chinese names, else the US; the China storefront is not served by the public search at all).
///
/// Privacy: sends the artist and title (or album) of the playing track to Apple — for streamed tracks, and for
/// files without artwork — only while a skin shows a cover. Turn it off with
/// `defaults write app.deskset.Deskset OnlineCoverLookup -bool NO` (docs/compat/media-ui.md).
enum NowPlayingCoverLookup {
    static let defaultsKey = "OnlineCoverLookup"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Answers by query (memory only; cleared when it grows past `cacheLimit`).
    private static var cache: [String: URL?] = [:]
    private static let lock = NSLock()
    private static let cacheLimit = 200
    private static let session = URLSession(configuration: .ephemeral)
    /// When the requests of the last minute were sent: Apple allows about 20 search requests a minute.
    private static var sent: [TimeInterval] = []
    static let requestsPerMinute = 15

    /// Storefronts to search, in order: at most two requests per track (pure; tested).
    static func storefronts(for track: NowPlayingTrack, region: String?) -> [String] {
        var list: [String] = []
        let home = (region ?? "").lowercased()
        // The public search answers nothing for the China storefront.
        if home.count == 2, home != "cn" { list.append(home) }
        let chinese = [track.artist, track.albumArtist, track.title, track.album].contains { hasHan($0) }
        for fallback in chinese ? ["tw", "hk", "us"] : ["us"] where !list.contains(fallback) {
            list.append(fallback)
        }
        return Array(list.prefix(2))
    }

    /// The search request for a track, or nil when there is not enough to search for.
    static func searchURL(for track: NowPlayingTrack, country: String) -> URL? {
        let artist = clean(track.artist.isEmpty ? track.albumArtist : track.artist)
        let title = clean(track.title)
        let album = clean(track.album)
        guard !artist.isEmpty, !title.isEmpty || !album.isEmpty else { return nil }
        let bySong = !title.isEmpty
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(bySong ? title : album)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: bySong ? "song" : "album"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: country.lowercased()),
        ]
        return components.url
    }

    /// The best result's artwork address in a Search API reply (pure; tested). The artist must match: one of the
    /// credited names, by name or by its romanization ("Yusheng Lin" for 林雨声), or — when the storefront writes it in
    /// another script ("Jay Chou" for 周杰伦) — through an exact title. And the song must match: its title (also
    /// without decorations such as "(Live)"), or its exact album (tracks of one album share the cover); another song
    /// of the same artist is no match. Nil when nothing matches.
    static func artworkURL(fromReply data: Data, track: NowPlayingTrack, size: Int = 600) -> URL? {
        guard data.count < 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        let artistName = track.artist.isEmpty ? track.albumArtist : track.artist
        let artist = normalized(artistName)
        let ourNames = artistNames(artistName).map(normalized).filter { !$0.isEmpty }
        let pinyins = artistNames(artistName).map(pinyinKey).filter { !$0.isEmpty }
        let artistIsLatin = isLatinScript(artistName)
        let bySong = !normalized(track.title).isEmpty
        var best: (score: Int, url: String)?
        for result in results.prefix(50) {
            guard let art = result["artworkUrl100"] as? String, art.hasPrefix("https://") else { continue }
            let name = result["artistName"] as? String ?? ""
            let titleScore = nameScore(result["trackName"] as? String ?? "", track.title, exact: 3, base: 2)
            let albumScore = nameScore(result["collectionName"] as? String ?? "", track.album, exact: 2, base: 1)
            var artistScore = 0
            let theirNames = artistNames(name)
            if !artist.isEmpty, normalized(name) == artist {
                artistScore = 3
            } else if theirNames.contains(where: { ourNames.contains(normalized($0)) }) {
                artistScore = 2
            } else if theirNames.contains(where: { n in pinyins.contains { romanizedMatch(n, pinyin: $0) } }) {
                artistScore = 2
            } else if !name.isEmpty, isLatinScript(name) != artistIsLatin, bySong ? titleScore == 3 : albumScore == 2 {
                artistScore = 1
            }
            guard artistScore > 0, bySong ? titleScore > 0 || albumScore == 2 : albumScore > 0 else { continue }
            let total = artistScore + titleScore + albumScore
            if best == nil || total > best!.score { best = (total, art) }
        }
        guard let chosen = best?.url else { return nil }
        // Ask for a bigger picture: only the file name part carries the size (`…/100x100bb.jpg`).
        guard let slash = chosen.lastIndex(of: "/") else { return URL(string: chosen) }
        let name = chosen[chosen.index(after: slash)...].replacingOccurrences(of: "100x100", with: "\(size)x\(size)")
        return URL(string: String(chosen[...slash]) + name)
    }

    /// `exact` when two titles are the same (see `normalized`), `base` when they are the same without decorations
    /// ("Glass (Live)" / "Glass", "晚风 - Single" / "晚风"), else 0.
    static func nameScore(_ theirs: String, _ ours: String, exact: Int, base: Int) -> Int {
        let a = normalized(theirs), b = normalized(ours)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return exact }
        return baseTitle(theirs) == baseTitle(ours) ? base : 0
    }

    /// A title without its decorations — parts in brackets and anything after " - " ("(Live)", "（伴奏）",
    /// "[Remastered]", " - Single") — normalized; the whole title when nothing else is left.
    static func baseTitle(_ s: String) -> String {
        var kept = ""
        var depth = 0
        for ch in s {
            if "(（[［【".contains(ch) {
                depth += 1
            } else if ")）]］】".contains(ch) {
                depth = max(depth - 1, 0)
            } else if depth == 0 {
                kept.append(ch)
            }
        }
        for dash in [" - ", " – ", " — "] {
            if let range = kept.range(of: dash) { kept = String(kept[..<range.lowerBound]) }
        }
        let base = normalized(kept)
        return base.isEmpty ? normalized(s) : base
    }

    /// The names in an artist credit: "A, B & C", "A feat. B", "A x B", "A、B", "A / B".
    static func artistNames(_ credit: String) -> [String] {
        var s = credit
        for joiner in [" feat. ", " feat ", " ft. ", " featuring ", " with ", " x ", " × ", " vs. ", " vs "] {
            s = s.replacingOccurrences(of: joiner, with: ",", options: .caseInsensitive)
        }
        return s.split { ",&、/;，＆".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Looks the cover up (asynchronously; `completion` runs on a background queue). `log` gets one line per request.
    static func find(_ track: NowPlayingTrack, log: @escaping (String) -> Void = { _ in },
                     completion: @escaping (URL?) -> Void) {
        let countries = storefronts(for: track, region: Locale.current.region?.identifier)
        search(track, countries: countries[...], log: log, completion: completion)
    }

    private static func search(_ track: NowPlayingTrack, countries: ArraySlice<String>,
                               log: @escaping (String) -> Void, completion: @escaping (URL?) -> Void) {
        guard let country = countries.first, let url = searchURL(for: track, country: country) else {
            return completion(nil)
        }
        let rest = countries.dropFirst()
        let key = url.absoluteString
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached {
            log("online \(country): \(cached?.absoluteString ?? "no match") (asked before)")
            if let cached { return completion(cached) }
            return search(track, countries: rest, log: log, completion: completion)
        }
        guard mayRequest() else {
            log("online \(country): not asked (\(requestsPerMinute) requests in the last minute)")
            return completion(nil)
        }
        let started = ProcessInfo.processInfo.systemUptime
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.setValue("Deskset", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(status)
            let found = ok ? data.flatMap { artworkURL(fromReply: $0, track: track) } : nil
            if ok {
                lock.lock()
                if cache.count >= cacheLimit { cache.removeAll() }
                cache[key] = .some(found)
                lock.unlock()
            }
            let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let outcome = ok ? (found?.absoluteString ?? "no match")
                : "failed (\(error.map { $0.localizedDescription } ?? "HTTP \(status)"))"
            log("online \(country): \(outcome) in \(ms) ms")
            if let found { return completion(found) }
            search(track, countries: rest, log: log, completion: completion)
        }.resume()
    }

    /// Counts a request against the per-minute limit; false when the limit is reached.
    private static func mayRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        sent.removeAll { now - $0 > 60 }
        guard sent.count < requestsPerMinute else { return false }
        sent.append(now)
        return true
    }

    /// `Deskset --cover-lookup ARTIST TITLE [ALBUM]`: the lookup NowPlaying does, with every request printed
    /// (diagnostics: why a track gets no cover).
    static func runCommand(_ arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--cover-lookup") else { return 2 }
        let names = arguments[(flag + 1)...].filter { !$0.hasPrefix("--") }
        guard names.count >= 2 else {
            fputs("usage: Deskset --cover-lookup ARTIST TITLE [ALBUM]\n", stderr)
            return 2
        }
        var track = NowPlayingTrack()
        track.artist = names[names.startIndex]
        track.title = names[names.startIndex + 1]
        track.album = names.count > 2 ? names[names.startIndex + 2] : ""
        let region = Locale.current.region?.identifier
        print("region \(region ?? "unknown"), storefronts: "
              + storefronts(for: track, region: region).joined(separator: ", "))
        let finished = DispatchSemaphore(value: 0)
        var cover: URL?
        find(track, log: { print($0) }) { url in
            cover = url
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 40)
        print("cover: " + (cover?.absoluteString ?? "none"))
        return cover == nil ? 1 : 0
    }

    /// Trimmed, single-spaced, at most 200 characters (the term goes into a URL).
    private static func clean(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace })
        return String(words.joined(separator: " ").prefix(200))
    }

    /// For matching: case, accents and width folded, Traditional Chinese as Simplified, without spaces, punctuation
    /// and symbols.
    static func normalized(_ s: String) -> String {
        var folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        if hasHan(folded) {
            folded = folded.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? folded
        }
        let scalars = folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The Mandarin reading of a name in letters only ("林雨声" → "linyusheng"); "" when it has no Chinese characters.
    static func pinyinKey(_ s: String) -> String {
        guard hasHan(s), let latin = s.applyingTransform(.mandarinToLatin, reverse: false) else { return "" }
        return latin.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isASCII && $0.isLetter }
    }

    /// A romanized name written given name first or family name first: "Yusheng Lin" and "Lin Yusheng" both match
    /// "linyusheng".
    static func romanizedMatch(_ name: String, pinyin: String) -> Bool {
        let words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty, words.allSatisfy({ $0.allSatisfy(\.isASCII) }) else { return false }
        return words.indices.contains { (words[$0...] + words[..<$0]).joined() == pinyin }
    }

    /// Whether every letter of `s` is Latin (and there is at least one).
    static func isLatinScript(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { $0.properties.isAlphabetic }
        return !letters.isEmpty && letters.allSatisfy { $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }
    }

    /// Whether `s` has Chinese characters (CJK ideographs).
    static func hasHan(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2EBEF).contains($0.value)
        }
    }
}
