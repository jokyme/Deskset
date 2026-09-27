import Foundation

/// "Did you mean" (§6.2, D119): case-insensitive match, then synonyms from the catalog's keywords, then edit
/// distance. Foreign spellings and "one level down" are looked up by the caller, which knows the kind of name.
enum DidYouMean {
    enum Via { case caseOnly, keyword, distance }

    struct Suggestion {
        /// At most three, best first.
        var names: [String]
        /// Whether a fix-it may be offered: a unique case match or synonym, or a unique candidate at distance 1.
        var fixable: Bool
        var via: Via?
        var distance: Int?
        /// Whether the best candidate is the only one at its distance (a farther one may still be fixed when it has
        /// the type the position expects, §6.2 step 5).
        var unique = false
    }

    /// Optimal string alignment (restricted Damerau–Levenshtein) distance on lower-cased names, stopping early once
    /// `limit` is exceeded.
    static func distance(_ a: String, _ b: String, limit: Int = .max) -> Int {
        let x = Array(a.lowercased().unicodeScalars), y = Array(b.lowercased().unicodeScalars)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous2 = [Int](repeating: 0, count: y.count + 1)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous2, &previous)
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// The largest distance accepted for a name of this length: 1 up to 4 characters, 2 up to 8, 3 beyond.
    static func threshold(for name: String) -> Int {
        let n = name.count
        return n <= 4 ? 1 : n <= 8 ? 2 : 3
    }

    /// The best suggestions for `name` among `candidates`. `keywords` maps a word to the candidates that list it as
    /// a synonym; `rank` breaks ties.
    static func suggest(_ name: String, candidates: [String], keywords: (String) -> [String] = { _ in [] },
                        rank: (String) -> Int = { _ in 0 }) -> Suggestion {
        let unique = Array(Set(candidates)).filter { $0 != name }
        // Case-insensitive exact match.
        let lowered = name.lowercased()
        let caseMatches = unique.filter { $0.lowercased() == lowered }
        if !caseMatches.isEmpty {
            return Suggestion(names: caseMatches.sorted(), fixable: caseMatches.count == 1, via: .caseOnly, distance: 0)
        }
        // Synonyms.
        let candidateSet = Set(unique)
        let synonyms = keywords(name).filter { candidateSet.contains($0) }
        var seen = Set<String>()
        let orderedSynonyms = synonyms.filter { seen.insert($0).inserted }
        if !orderedSynonyms.isEmpty {
            let sorted = orderedSynonyms.sorted { rank($0) > rank($1) }
            return Suggestion(names: Array(sorted.prefix(3)), fixable: sorted.count == 1, via: .keyword, distance: nil)
        }
        // Edit distance.
        let limit = threshold(for: name)
        var scored: [(name: String, distance: Int, prefix: Int, rank: Int)] = []
        for candidate in unique {
            let d = distance(name, candidate, limit: limit)
            guard d <= limit else { continue }
            scored.append((candidate, d, commonPrefix(lowered, candidate.lowercased()), rank(candidate)))
        }
        scored.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.prefix != b.prefix { return a.prefix > b.prefix }
            if a.rank != b.rank { return a.rank > b.rank }
            return a.name < b.name
        }
        guard let best = scored.first else { return Suggestion(names: [], fixable: false, via: nil, distance: nil) }
        let uniqueBest = scored.filter { $0.distance == best.distance }.count == 1
        return Suggestion(names: scored.prefix(3).map(\.name), fixable: uniqueBest && best.distance == 1, via: .distance,
                          distance: best.distance, unique: uniqueBest)
    }

    /// The single closest name, or nil.
    static func closest(_ name: String, among candidates: [String]) -> String? {
        suggest(name, candidates: candidates).names.first
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a.unicodeScalars, b.unicodeScalars) {
            guard x == y else { break }
            n += 1
        }
        return n
    }

    /// A lowerCamel own name made from a label: "Show seconds" → `showSeconds`.
    static func lowerCamel(from label: String) -> String {
        let words = label.unicodeScalars.split { !(CharacterSet.alphanumerics.contains($0) && $0.isASCII) }.map { String($0) }
        guard !words.isEmpty else { return "option" }
        var result = words[0].lowercased()
        for word in words.dropFirst() { result += word.prefix(1).uppercased() + word.dropFirst().lowercased() }
        if let first = result.unicodeScalars.first, ("0"..."9").contains(first) { result = "option" + result }
        return result
    }
}
